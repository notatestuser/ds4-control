import Foundation
import Combine

@MainActor
final class SupervisorService: ObservableObject {
    @Published private(set) var state: ServerState = .idle
    @Published private(set) var activeModel: String?
    @Published private(set) var port: Int = 8000
    @Published private(set) var ctx: Int = 393_216
    @Published private(set) var health: HealthStatus?
    // Populated by download(variant:) — see Task 9.
    @Published private(set) var download: DownloadProgress?
    @Published private(set) var recentLog: [String] = []

    var thinkMaxActive: Bool { thinkMax(ctx: ctx) }

    let ds4Dir: URL
    let runner: ProcessRunner
    private var stderrTail: [String] = []
    private var expectingExit = false
    private var healthTimer: Timer?
    private var startupTimer: Timer?

    init(ds4Dir: URL, runner: ProcessRunner) {
        self.ds4Dir = ds4Dir
        self.runner = runner
    }

    deinit {
        healthTimer?.invalidate()
        startupTimer?.invalidate()
    }

    // MARK: - Path resolution
    private func ggufURL(for variant: Variant, ramGiB: Double) -> URL {
        let q = Quant.for(variant, ramGiB: ramGiB)
        let base =
            ProcessInfo.processInfo.environment["DS4_GGUF_DIR"].map(URL.init(fileURLWithPath:))
            ?? ds4Dir.appendingPathComponent("gguf")
        return base.appendingPathComponent(q.ggufFilename)
    }
    private func validateDs4Dir() -> ServerError? {
        for f in ["ds4-server", "download_model.sh"] {
            let u = ds4Dir.appendingPathComponent(f)
            if !FileManager.default.isExecutableFile(atPath: u.path) { return .ds4DirInvalid(missing: f) }
        }
        return nil
    }

    // MARK: - Start
    func start(variant: Variant, ctx: Int, port: Int, power: Int?) {
        guard state == .idle || isErrorState else { emitBadState("start"); return }
        if let e = validateDs4Dir() { state = .error(e); return }
        let ram = systemRamGiB()
        let gguf = ggufURL(for: variant, ramGiB: ram)
        guard FileManager.default.fileExists(atPath: gguf.path) else {
            state = .error(.modelMissing(filename: gguf.lastPathComponent)); return
        }
        self.port = port; self.ctx = ctx; self.activeModel = variant.modelId
        stderrTail = []; expectingExit = false
        var args = ["-m", gguf.path, "--ctx", "\(ctx)", "--host", "127.0.0.1", "--port", "\(port)", "--metal"]
        if let power { args += ["--power", "\(power)"] }
        state = .starting
        do {
            try runner.launch(
                executable: ds4Dir.appendingPathComponent("ds4-server"),
                args: args, cwd: ds4Dir,
                onStderrLine: { [weak self] line in Self.onMain { self?.handleStderr(line) } },
                onExit: { [weak self] code in Self.onMain { self?.handleExit(code) } })
        } catch {
            state = .error(.crashed(tail: "\(error)")); return
        }
        startupTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in
            Task { @MainActor in if self?.state == .starting { self?.fail(.startupTimeout) } }
        }
    }

    private func handleStderr(_ line: String) {
        recentLog.append(line); stderrTail.append(line)
        if stderrTail.count > 50 { stderrTail.removeFirst(stderrTail.count - 50) }
        if state == .starting, isReadyLine(line) {
            startupTimer?.invalidate(); startupTimer = nil
            state = .ready
            startHealthPolling()
        }
    }

    private func handleExit(_ code: Int32) {
        healthTimer?.invalidate(); healthTimer = nil; startupTimer?.invalidate(); startupTimer = nil
        if expectingExit { state = .idle; return }
        state = .error(.crashed(tail: stderrTail.suffix(10).joined(separator: "\n")))
    }

    // MARK: - Stop
    func stop() {
        guard state == .ready || state == .starting else { emitBadState("stop"); return }
        expectingExit = true
        state = .stopping
        healthTimer?.invalidate(); healthTimer = nil
        startupTimer?.invalidate(); startupTimer = nil
        runner.terminate(graceSeconds: 30)
    }

    // MARK: - Download
    private let downloadRunner = RealProcessRunner()

    func download(variant: Variant) {
        guard state == .idle || isErrorState else { emitBadState("download"); return }
        if let e = validateDs4Dir() { state = .error(e); return }
        let q = Quant.for(variant, ramGiB: systemRamGiB())
        download = DownloadProgress(pct: 0, file: q.ggufFilename, receivedBytes: 0, totalBytes: nil)
        state = .downloading
        var buf = ""
        do {
            try downloadRunner.launch(
                executable: ds4Dir.appendingPathComponent("download_model.sh"),
                args: [q.arg], cwd: ds4Dir,
                onStderrLine: { [weak self] line in
                    buf += line + "\n"
                    let pct = parseCurlProgress(buf)
                    Self.onMain {
                        guard let self else { return }
                        if let pct {
                            self.download = DownloadProgress(
                                pct: pct, file: q.ggufFilename, receivedBytes: 0, totalBytes: nil)
                        }
                    }
                },
                onExit: { [weak self] code in
                    Self.onMain {
                        guard let self else { return }
                        if code == 0 {
                            self.download = DownloadProgress(
                                pct: 100, file: q.ggufFilename, receivedBytes: 0, totalBytes: nil)
                            self.state = .idle
                        } else {
                            self.state = .error(.downloadFailed(detail: "exit \(code)"))
                        }
                    }
                })
        } catch { state = .error(.downloadFailed(detail: "\(error)")) }
    }

    /// True when the selected variant's gguf exists on disk.
    func isDownloaded(_ variant: Variant) -> Bool {
        FileManager.default.fileExists(atPath: ggufURL(for: variant, ramGiB: systemRamGiB()).path)
    }

    // MARK: - Health
    private func startHealthPolling() {
        pollHealth()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollHealth() }
        }
    }
    private var healthFailures = 0
    private func pollHealth() {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        let start = Date()
        URLSession.shared.dataTask(with: url) { [weak self] _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            Task { @MainActor in
                // The `.ready` guard is load-bearing: it makes a stale in-flight health callback a no-op after stop(). Do not remove.
                guard let self, self.state == .ready else { return }
                self.health = HealthStatus(ok: ok, latencyMs: Int(Date().timeIntervalSince(start) * 1000))
                self.healthFailures = ok ? 0 : self.healthFailures + 1
                if self.healthFailures >= 3 && self.runner.isRunning { self.fail(.unhealthy) }
            }
        }.resume()
    }

    // MARK: - helpers
    /// Run `body` on the MainActor. Process callbacks (RealProcessRunner) arrive on a
    /// background queue → hop via Task; synchronous callers already on the main thread
    /// (e.g. the test FakeRunner) run immediately so state transitions are observable
    /// in the same turn.
    private static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            Task { @MainActor in body() }
        }
    }
    private var isErrorState: Bool { if case .error = state { return true }; return false }
    private func fail(_ e: ServerError) {
        healthTimer?.invalidate(); healthTimer = nil; startupTimer?.invalidate(); startupTimer = nil; state = .error(e)
    }
    private func emitBadState(_ cmd: String) { recentLog.append("ignored '\(cmd)' in state \(state)") }
}
