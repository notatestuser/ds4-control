import Foundation

struct CapturedProcessOutput {
    let standardOutput: Data
    let standardError: Data
}

private final class ProcessPipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var standardOutput = Data()
    private var standardError = Data()

    func setStandardOutput(_ data: Data) {
        lock.withLock { standardOutput = data }
    }

    func setStandardError(_ data: Data) {
        lock.withLock { standardError = data }
    }

    func output() -> CapturedProcessOutput {
        lock.withLock {
            CapturedProcessOutput(standardOutput: standardOutput, standardError: standardError)
        }
    }
}

/// Drain both pipes while the child is running so neither can fill and deadlock the wait.
func runAndCaptureOutput(
    _ process: Process, standardOutput: Pipe, standardError: Pipe
) throws -> CapturedProcessOutput {
    try process.run()
    let capture = ProcessPipeCapture()
    let group = DispatchGroup()
    let drainQueue = DispatchQueue(label: "ds4.process-pipe-drain", attributes: .concurrent)
    group.enter()
    drainQueue.async {
        capture.setStandardOutput(standardOutput.fileHandleForReading.readDataToEndOfFile())
        group.leave()
    }
    group.enter()
    drainQueue.async {
        capture.setStandardError(standardError.fileHandleForReading.readDataToEndOfFile())
        group.leave()
    }
    process.waitUntilExit()
    group.wait()
    return capture.output()
}

protocol ProcessRunner: AnyObject {
    /// Launch `executable` with `args` in `cwd`; `env` is merged over the inherited
    /// environment, then `removingEnvironmentKeys` is removed from the child only.
    /// Delivers stderr lines and termination.
    func launch(
        executable: URL, args: [String], cwd: URL, env: [String: String],
        removingEnvironmentKeys: Set<String>,
        onStderrLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void) throws
    func terminate(graceSeconds: Double)
    var isRunning: Bool { get }
}

/// Buffers a process's stderr into newline-delimited lines. `FileHandle` invokes the
/// readability handler serially on its own private queue, so the mutable buffer is never
/// accessed concurrently — hence the `@unchecked Sendable` conformance (Swift 6 mode).
private final class StderrLineReader: @unchecked Sendable {
    private let handle: FileHandle
    private let onLine: @Sendable (String) -> Void
    private var buffer = Data()

    init(handle: FileHandle, onLine: @escaping @Sendable (String) -> Void) {
        self.handle = handle
        self.onLine = onLine
    }

    func start() {
        handle.readabilityHandler = { [self] h in
            buffer.append(h.availableData)
            while let nl = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(data: buffer[..<nl], encoding: .utf8) ?? ""
                buffer.removeSubrange(...nl)
                onLine(line)
            }
        }
    }

    func stop() { handle.readabilityHandler = nil }
}

final class RealProcessRunner: ProcessRunner {
    private var process: Process?
    private let queue = DispatchQueue(label: "ds4.process")

    var isRunning: Bool { process?.isRunning ?? false }

    func launch(
        executable: URL, args: [String], cwd: URL, env: [String: String],
        removingEnvironmentKeys: Set<String>,
        onStderrLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        let p = Process()
        p.executableURL = executable
        p.arguments = args
        p.currentDirectoryURL = cwd
        if !env.isEmpty || !removingEnvironmentKeys.isEmpty {
            p.environment = Self.childEnvironment(
                inherited: ProcessInfo.processInfo.environment,
                overrides: env,
                removing: removingEnvironmentKeys)
        }
        let err = Pipe()
        p.standardError = err
        let reader = StderrLineReader(handle: err.fileHandleForReading, onLine: onStderrLine)
        reader.start()
        p.terminationHandler = { proc in
            reader.stop()
            onExit(proc.terminationStatus)
        }
        try p.run()
        self.process = p
    }

    static func childEnvironment(
        inherited: [String: String], overrides: [String: String], removing: Set<String>
    ) -> [String: String] {
        var result = inherited
        for (key, value) in overrides { result[key] = value }
        for key in removing { result.removeValue(forKey: key) }
        return result
    }

    func terminate(graceSeconds: Double) {
        guard let p = process else { return }
        // download_model.sh spawns `hf` as a child; SIGTERM to the shell alone orphans
        // hf, which keeps holding the hf download lock and blocks the next attempt.
        // Capture descendants *before* killing (they reparent to launchd once the shell
        // dies, so pgrep -P would then find nothing) and signal the whole tree.
        let queue = queue
        queue.async { [weak p] in
            guard let p, p.isRunning else { return }
            let kids = Self.descendantPIDs(of: p.processIdentifier)
            p.terminate()  // SIGTERM the shell
            for k in kids { kill(k, SIGTERM) }
            queue.asyncAfter(deadline: .now() + graceSeconds) { [weak p] in
                if let p, p.isRunning { kill(p.processIdentifier, SIGKILL) }
                for k in kids where kill(k, 0) == 0 { kill(k, SIGKILL) }
            }
        }
    }

    /// All descendant PIDs of `pid` (children, grandchildren, …) via `pgrep -P`.
    private static func descendantPIDs(of pid: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var frontier: [pid_t] = [pid]
        while let cur = frontier.popLast() {
            for child in childPIDs(of: cur) where !found.contains(child) {
                found.append(child)
                frontier.append(child)
            }
        }
        return found
    }

    private static func childPIDs(of pid: pid_t) -> [pid_t] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-P", "\(pid)"]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        guard let output = try? runAndCaptureOutput(proc, standardOutput: out, standardError: err)
        else { return [] }
        return String(decoding: output.standardOutput, as: UTF8.self)
            .split(whereSeparator: { $0 == "\n" })
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }
}
