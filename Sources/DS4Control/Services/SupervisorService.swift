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
    private var downloadPollTimer: Timer?
    private var lastDownloadSample: (bytes: Int64, time: Date)?
    /// True when tracking a download started by a previous session (we poll its
    /// .incomplete file but don't own the process — see resumeInFlightDownloadIfAny).
    private var downloadAttached = false
    private var staleDownloadPolls = 0

    init(ds4Dir: URL, runner: ProcessRunner) {
        self.ds4Dir = ds4Dir
        self.runner = runner
    }

    deinit {
        healthTimer?.invalidate()
        startupTimer?.invalidate()
        downloadPollTimer?.invalidate()
    }

    // MARK: - Path resolution
    private func ggufBaseDir() -> URL {
        ProcessInfo.processInfo.environment["DS4_GGUF_DIR"].map(URL.init(fileURLWithPath:))
            ?? ds4Dir.appendingPathComponent("gguf")
    }
    private func ggufURL(for variant: Variant, ramGiB: Double) -> URL {
        ggufBaseDir().appendingPathComponent(Quant.for(variant, ramGiB: ramGiB).ggufFilename)
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
                args: args, cwd: ds4Dir, env: [:],
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
        let baseDir = ggufBaseDir()
        let expectedBytes = Int64(q.weightsGiB * 1_073_741_824)
        download = DownloadProgress(pct: 0, file: q.ggufFilename, receivedBytes: 0, totalBytes: expectedBytes)
        state = .downloading
        downloadAttached = false
        // Progress comes from polling the file on disk: the hf downloader emits no
        // parseable progress to a non-TTY pipe, so stderr-parsing alone stays at 0%.
        startDownloadPolling(baseDir: baseDir, filename: q.ggufFilename, expected: expectedBytes)
        var buf = ""
        let args = [q.arg]
        // Optional auth: pass any HF_TOKEN (env or hf cache) to the child via the
        // environment so hf can authenticate — never on the command line (no ps leak).
        var env: [String: String] = [:]
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/token")
        if let token = resolveHFToken(env: ProcessInfo.processInfo.environment, cacheFile: cache) {
            env["HF_TOKEN"] = token
        }
        do {
            try downloadRunner.launch(
                executable: ds4Dir.appendingPathComponent("download_model.sh"),
                args: args, cwd: ds4Dir, env: env,
                onStderrLine: { [weak self] line in
                    buf += line + "\n"
                    // Bound the buffer: downloads run for hours and emit a progress
                    // repaint per tick; keep only the tail (latest update lives there).
                    if buf.count > 4096 { buf = String(buf.suffix(2048)) }
                    let pct = parseCurlProgress(buf)
                    let rate = parseDownloadRate(buf)
                    Self.onMain {
                        guard let self else { return }
                        if let pct {
                            self.download = DownloadProgress(
                                pct: pct, file: q.ggufFilename, receivedBytes: 0, totalBytes: nil, rate: rate)
                        }
                    }
                },
                onExit: { [weak self] code in
                    Self.onMain {
                        guard let self else { return }
                        self.downloadPollTimer?.invalidate()
                        self.downloadPollTimer = nil
                        if code == 0 {
                            self.download = DownloadProgress(
                                pct: 100, file: q.ggufFilename, receivedBytes: 0, totalBytes: nil)
                            self.state = .idle
                        } else {
                            self.state = .error(.downloadFailed(detail: "exit \(code)"))
                        }
                    }
                })
        } catch {
            downloadPollTimer?.invalidate()
            downloadPollTimer = nil
            state = .error(.downloadFailed(detail: "\(error)"))
        }
    }

    /// Cancel whatever download is being tracked (owned process or an attached
    /// orphan) and start a fresh one — the user's escape hatch from a stuck/stalled
    /// or errored progress bar.
    func retryDownload(variant: Variant) {
        downloadRunner.terminate(graceSeconds: 0)  // no-op if nothing is running
        downloadPollTimer?.invalidate()
        downloadPollTimer = nil
        downloadAttached = false
        lastDownloadSample = nil
        download = nil
        state = .idle
        download(variant: variant)
    }

    /// If a download is already in flight from a previous session (an .incomplete
    /// file under the hf cache) and we're idle, re-attach the progress UI without
    /// spawning a new download — avoids the hf lock collision a re-click would cause.
    /// Variant-agnostic on the partial bytes; uses the selected variant for the total.
    func resumeInFlightDownloadIfAny(variant: Variant) {
        guard state == .idle else { return }
        let base = ggufBaseDir()
        let q = Quant.for(variant, ramGiB: systemRamGiB())
        // Already fully downloaded → nothing to attach.
        if FileManager.default.fileExists(atPath: base.appendingPathComponent(q.ggufFilename).path) { return }
        let received = downloadedBytes(ggufDir: base, filename: q.ggufFilename)
        guard received > 0 else { return }  // no in-flight partial
        let expected = Int64(q.weightsGiB * 1_073_741_824)
        downloadAttached = true
        let pct = expected > 0 ? min(100, Double(received) / Double(expected) * 100) : 0
        download = DownloadProgress(pct: pct, file: q.ggufFilename, receivedBytes: received, totalBytes: expected)
        state = .downloading
        startDownloadPolling(baseDir: base, filename: q.ggufFilename, expected: expected)
    }

    private func startDownloadPolling(baseDir: URL, filename: String, expected: Int64) {
        lastDownloadSample = nil
        staleDownloadPolls = 0
        downloadPollTimer?.invalidate()
        downloadPollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollDownload(baseDir: baseDir, filename: filename, expected: expected) }
        }
    }

    /// Poll the on-disk download size to publish % and rate (TTY-independent).
    private func pollDownload(baseDir: URL, filename: String, expected: Int64) {
        guard state == .downloading else {
            downloadPollTimer?.invalidate()
            downloadPollTimer = nil
            return
        }
        // Attached (externally-owned) download completed: the final file appeared.
        if downloadAttached, FileManager.default.fileExists(atPath: baseDir.appendingPathComponent(filename).path) {
            download = DownloadProgress(pct: 100, file: filename, receivedBytes: 0, totalBytes: nil)
            endAttachedDownload()
            return
        }
        let received = downloadedBytes(ggufDir: baseDir, filename: filename)
        if downloadAttached {
            if let last = lastDownloadSample, received <= last.bytes {
                staleDownloadPolls += 1
                if staleDownloadPolls >= 10 {
                    // ~10s without growth. If the external downloader is still alive
                    // (slow network, or finalizing/verifying near 100%), keep showing
                    // progress; only revert to idle if the process is truly gone, so a
                    // click resumes from the .incomplete (and never collides with a
                    // running download's hf lock).
                    if isDownloadProcessRunning() {
                        staleDownloadPolls = 0
                    } else {
                        endAttachedDownload()
                        return
                    }
                }
            } else {
                staleDownloadPolls = 0
            }
        }
        guard received > 0 else { return }  // nothing on disk yet — leave any stderr-driven value
        let now = Date()
        var rate: String?
        if let last = lastDownloadSample, received > last.bytes {
            let dt = now.timeIntervalSince(last.time)
            if dt > 0.1 { rate = formatRate(Double(received - last.bytes) / dt) }
        }
        lastDownloadSample = (received, now)
        let pct = expected > 0 ? min(100, Double(received) / Double(expected) * 100) : 0
        download = DownloadProgress(
            pct: pct, file: filename, receivedBytes: received, totalBytes: expected, rate: rate ?? download?.rate)
    }

    /// Whether ds4's downloader (download_model.sh / hf for this repo) is running.
    /// Used only when growth stalls, to distinguish "slow/finalizing" from "dead".
    private func isDownloadProcessRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "download_model|deepseek-v4-gguf"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return false
        }
        return p.terminationStatus == 0
    }

    private func endAttachedDownload() {
        downloadAttached = false
        staleDownloadPolls = 0
        downloadPollTimer?.invalidate()
        downloadPollTimer = nil
        state = .idle
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
