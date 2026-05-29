import Foundation

protocol ProcessRunner: AnyObject {
    /// Launch `executable` with `args` in `cwd`; deliver stderr lines and termination.
    func launch(
        executable: URL, args: [String], cwd: URL,
        onStderrLine: @escaping (String) -> Void,
        onExit: @escaping (Int32) -> Void) throws
    func terminate(graceSeconds: Double)
    var isRunning: Bool { get }
}

final class RealProcessRunner: ProcessRunner {
    private var process: Process?
    private let queue = DispatchQueue(label: "ds4.process")

    var isRunning: Bool { process?.isRunning ?? false }

    func launch(
        executable: URL, args: [String], cwd: URL,
        onStderrLine: @escaping (String) -> Void,
        onExit: @escaping (Int32) -> Void
    ) throws {
        let p = Process()
        p.executableURL = executable
        p.arguments = args
        p.currentDirectoryURL = cwd
        let err = Pipe()
        p.standardError = err
        var buffer = Data()
        err.fileHandleForReading.readabilityHandler = { h in
            buffer.append(h.availableData)
            while let nl = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(data: buffer[..<nl], encoding: .utf8) ?? ""
                buffer.removeSubrange(...nl)
                onStderrLine(line)
            }
        }
        p.terminationHandler = { proc in
            err.fileHandleForReading.readabilityHandler = nil
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
