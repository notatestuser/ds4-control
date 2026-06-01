import Foundation

protocol ProcessRunner: AnyObject {
    /// Launch `executable` with `args` in `cwd`; `env` is merged over the inherited
    /// environment (used to pass HF_TOKEN securely, never on the command line).
    /// Delivers stderr lines and termination.
    func launch(
        executable: URL, args: [String], cwd: URL, env: [String: String],
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
        onStderrLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        let p = Process()
        p.executableURL = executable
        p.arguments = args
        p.currentDirectoryURL = cwd
        if !env.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            p.environment = merged
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

    func terminate(graceSeconds: Double) {
        guard let p = process, p.isRunning else { return }
        p.terminate()  // SIGTERM
        queue.asyncAfter(deadline: .now() + graceSeconds) { [weak p] in
            if let p, p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }
}
