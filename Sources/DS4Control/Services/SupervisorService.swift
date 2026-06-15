import Foundation
import Combine

/// Reference box so the `@Sendable` stderr callback can accumulate downloader output
/// across invocations. The process reader calls the callback serially, so the single
/// mutable field is never touched concurrently — hence `@unchecked Sendable`.
private final class DownloadStderrBuffer: @unchecked Sendable {
    var text = ""
}

@MainActor
final class SupervisorService: ObservableObject {
    @Published private(set) var state: ServerState = .idle
    @Published private(set) var activeModel: String?
    @Published private(set) var port: Int = 8000
    @Published private(set) var ctx: Int = 393_216
    @Published private(set) var health: HealthStatus?
    // Populated by download(variant:) — see Task 9.
    @Published private(set) var download: DownloadProgress?
    /// True only while a download process is confirmed alive — our own, or (for a download
    /// resumed from a prior session) one found via pgrep. Drives the live spinner; refreshed
    /// every poll tick so it clears within ~1s of the process stopping or being killed.
    @Published private(set) var downloadProcessLive = false
    @Published private(set) var recentLog: [String] = []
    /// Bumped whenever the on-disk gguf set changes via cleanup, so SwiftUI views that read
    /// `isFlashQuantDownloaded` (the Settings picker) re-render.
    @Published private(set) var ggufStoreVersion = 0

    var thinkMaxActive: Bool { thinkMax(ctx: ctx) }

    let ds4Dir: URL
    let runner: ProcessRunner
    /// Probes a port for a running ds4-server; returns the /v1/models body on HTTP 200,
    /// else nil. Injectable so tests don't depend on a live socket (default hits the
    /// real local server via URLSession).
    let serverProbe: (Int) async -> Data?
    private var stderrTail: [String] = []
    private var expectingExit = false
    private var healthTimer: Timer?
    private var startupTimer: Timer?
    /// Last (bytes, time) sample from the download progress callback, for the transfer-rate delta.
    private var lastDownloadSample: (bytes: Int64, time: Date)?
    /// True when attached to a ds4-server started by a previous session (we don't
    /// own the process; Stop terminates it by port — see resumeRunningServerIfAny).
    private var serverAttached = false
    /// Deferred start used by `restart`: when stopping an owned process, the relaunch
    /// can't happen until it has fully exited (port freed). `handleExit` runs this.
    private var pendingRestart: (() -> Void)?

    /// Where downloaded gguf models live when `DS4_GGUF_DIR` isn't set. Production passes
    /// the writable App Support dir; tests pass nil so it falls back to `ds4Dir/gguf`.
    private let ggufBaseOverride: URL?

    /// The pluggable file fetch — defaults to the native parallel `HFDownloader`. Tests inject a fake
    /// that simulates progress/completion/failure without touching the network. `highPerformance`
    /// selects the worker count (14 vs 64).
    typealias FetchFile =
        @Sendable (
            _ file: String, _ destDir: URL, _ token: String?, _ highPerformance: Bool,
            _ onProgress: @escaping @Sendable (Int64, Int64) -> Void
        ) async throws -> Void
    private let fetchFile: FetchFile

    init(
        ds4Dir: URL, runner: ProcessRunner, serverProbe: ((Int) async -> Data?)? = nil,
        ggufBaseURL: URL? = nil, downloadRunner: ProcessRunner? = nil, fetchFile: FetchFile? = nil
    ) {
        self.ds4Dir = ds4Dir
        self.runner = runner
        self.serverProbe = serverProbe ?? SupervisorService.defaultServerProbe
        self.ggufBaseOverride = ggufBaseURL
        self.downloadRunner = downloadRunner ?? RealProcessRunner()
        self.fetchFile =
            fetchFile ?? { file, dir, token, highPerformance, prog in
                try await HFDownloader(repo: SupervisorService.ggufRepo).download(
                    file: file, into: dir, token: token, highPerformance: highPerformance, onProgress: prog)
            }
    }

    /// Disk KV-cache directory — writable (App Support), not the read-only bundle.
    var kvDiskCacheURL: URL { ds4AppSupportDir().appendingPathComponent("kv", isDirectory: true) }

    /// Default probe: GET http://127.0.0.1:<port>/v1/models, returning the body on 200.
    static func defaultServerProbe(_ port: Int) async -> Data? {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
            (resp as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    // Timers are invalidated in stop()/finish()/fail() and on handleExit; the supervisor
    // itself is an app-lifetime @StateObject, so no deinit cleanup is needed (and a
    // nonisolated deinit can't touch these MainActor-isolated, non-Sendable Timers).

    // MARK: - Path resolution
    private func ggufBaseDir() -> URL {
        if let env = ProcessInfo.processInfo.environment["DS4_GGUF_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return ggufBaseOverride ?? ds4Dir.appendingPathComponent("gguf")
    }
    private func ggufURL(for variant: Variant, flashQuant: FlashQuant) -> URL {
        ggufBaseDir().appendingPathComponent(Quant.for(variant, flashQuant: flashQuant).ggufFilename)
    }
    private func validateDs4Dir() -> ServerError? {
        for f in ["ds4-server", "download_model.sh"] {
            let u = ds4Dir.appendingPathComponent(f)
            if !FileManager.default.isExecutableFile(atPath: u.path) { return .ds4DirInvalid(missing: f) }
        }
        return nil
    }

    // MARK: - Start
    /// Disk KV-cache budget (MB) when `kvDiskDir` is provided. ds4's compressed KV
    /// is tiny, so this holds many cached prefixes; generous but trivial on modern SSDs.
    static let kvDiskSpaceMB = 16384

    func start(variant: Variant, flashQuant: FlashQuant, ctx: Int, port: Int, power: Int?, kvDiskDir: URL? = nil) {
        guard state == .idle || isErrorState else { emitBadState("start"); return }
        if let e = validateDs4Dir() { state = .error(e); return }
        let quant = Quant.for(variant, flashQuant: flashQuant)
        let gguf = ggufURL(for: variant, flashQuant: flashQuant)
        guard FileManager.default.fileExists(atPath: gguf.path) else {
            state = .error(.modelMissing(filename: gguf.lastPathComponent)); return
        }
        if let validationError = downloadedModelValidationError(gguf, quant: quant) {
            state = .error(.modelInvalid(filename: gguf.lastPathComponent, detail: validationError.description))
            return
        }
        self.port = port; self.ctx = ctx; self.activeModel = variant.modelId
        stderrTail = []; expectingExit = false; serverAttached = false
        var args = ["-m", gguf.path, "--ctx", "\(ctx)", "--host", "127.0.0.1", "--port", "\(port)", "--metal"]
        if let power { args += ["--power", "\(power)"] }
        if let kvDiskDir {
            // Persist compressed KV to disk so repeated/large prefixes (coding agents)
            // skip re-prefill across turns and restarts. README: "KV cache is a
            // first-class disk citizen." Created here so the path always exists.
            try? FileManager.default.createDirectory(at: kvDiskDir, withIntermediateDirectories: true)
            args += ["--kv-disk-dir", kvDiskDir.path, "--kv-disk-space-mb", "\(Self.kvDiskSpaceMB)"]
        }
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
        if expectingExit {
            state = .idle
            if let relaunch = pendingRestart { pendingRestart = nil; relaunch() }
            return
        }
        pendingRestart = nil
        state = .error(.crashed(tail: stderrTail.suffix(10).joined(separator: "\n")))
    }

    // MARK: - Stop
    func stop() {
        guard state == .ready || state == .starting else { emitBadState("stop"); return }
        expectingExit = true
        state = .stopping
        healthTimer?.invalidate(); healthTimer = nil
        startupTimer?.invalidate(); startupTimer = nil
        if serverAttached {
            // We don't own the process (attached on launch) — terminate the listener.
            killProcessListening(onPort: port)
            serverAttached = false
            state = .idle
        } else {
            runner.terminate(graceSeconds: 30)
        }
    }

    /// Apply changed settings to a running server: stop it, then relaunch with the
    /// supplied parameters once it has fully exited (so the port is free). When the
    /// running server was owned by us, `stop()` drains asynchronously and the relaunch
    /// is deferred to `handleExit`; an attached orphan stops synchronously and relaunches
    /// at once. No-op unless a server is running.
    func restart(variant: Variant, flashQuant: FlashQuant, ctx: Int, port: Int, power: Int?, kvDiskDir: URL? = nil) {
        guard state == .ready || state == .starting else { emitBadState("restart"); return }
        let relaunch: () -> Void = { [weak self] in
            guard let self else { return }
            self.start(
                variant: variant, flashQuant: flashQuant, ctx: ctx, port: port, power: power,
                kvDiskDir: kvDiskDir)
        }
        stop()
        if state == .idle {
            relaunch()  // stopped synchronously (attached, or the runner exited inline)
        } else {
            pendingRestart = relaunch  // owned process draining its grace period
        }
    }

    /// On launch, if a ds4-server is already serving on `port` (orphaned from a prior
    /// session, model still loaded), attach to it as `.ready` instead of spawning a
    /// new one — avoids a port conflict and a second multi-hundred-GB load.
    func resumeRunningServerIfAny(port: Int) {
        guard state == .idle else { return }
        Task { [weak self] in
            guard let probe = self?.serverProbe else { return }
            let data = await probe(port)
            await MainActor.run {
                guard let self, self.state == .idle, let data else { return }
                self.serverAttached = true
                self.port = port
                self.activeModel = loadedModelName(from: data) ?? "ds4-server"
                // Adopted server: take its real context window from /v1/models so the chat
                // meter reflects the running `--ctx`, not the start-time default.
                if let loaded = loadedContextLength(from: data) { self.ctx = loaded }
                self.state = .ready
                self.startHealthPolling()
            }
        }
    }

    private func killProcessListening(onPort port: Int) {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "tcp:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = Pipe()
        do {
            try lsof.run()
            lsof.waitUntilExit()
        } catch {
            return
        }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in out.split(whereSeparator: { $0 == "\n" }) {
            if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) { kill(pid, SIGTERM) }
        }
    }

    // MARK: - Download
    private let downloadRunner: ProcessRunner
    /// Bumped on every download()/retry. Stale stderr/exit callbacks from a superseded
    /// (e.g. terminated-on-retry) process carry an old generation and are ignored, so a
    /// SIGTERM'd process's exit-15 can't clobber the fresh download's state.
    private var downloadGeneration = 0
    /// The native HF download in flight (nil when idle); cancelled by cancelDownload()/retry.
    private var downloadTask: Task<Void, Never>?
    /// HuggingFace repo hosting the DS4 GGUF weights (single source for the resolve URL).
    private static let ggufRepo = "antirez/deepseek-v4-gguf"

    func download(variant: Variant, flashQuant: FlashQuant, highPerformance: Bool = false) {
        guard state == .idle || isErrorState else { emitBadState("download"); return }
        if let e = validateDs4Dir() { state = .error(e); return }
        let q = Quant.for(variant, flashQuant: flashQuant)
        let baseDir = ggufBaseDir()
        let expectedBytes = Int64(q.weightsGiB * 1_073_741_824)
        download = DownloadProgress(pct: 0, file: q.ggufFilename, receivedBytes: 0, totalBytes: expectedBytes)
        state = .downloading
        lastDownloadSample = nil
        downloadGeneration += 1
        let gen = downloadGeneration
        let token = resolveHFToken(
            env: ProcessInfo.processInfo.environment,
            cacheFile: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/huggingface/token"))
        let filename = q.ggufFilename
        downloadProcessLive = true
        // Native parallel Swift download: N workers each GET …/resolve/main/<file> with a closed
        // HTTP Range straight to their offset in `<file>.part`, re-resolving each chunk so the signed
        // URL never expires. No `hf` CLI, curl, or download_model.sh. Progress is byte-accurate from
        // the downloader's onProgress callback (the sparse `.part` size is meaningless), hopped to the
        // main actor and turned into pct/rate by updateDownloadProgress — no on-disk poll for progress.
        let fetch = fetchFile
        downloadTask?.cancel()
        downloadTask = Task { [weak self] in
            do {
                try await fetch(filename, baseDir, token, highPerformance) { received, total in
                    Self.onMain {
                        self?.updateDownloadProgress(gen: gen, file: filename, received: received, total: total)
                    }
                }
                Self.onMain { self?.completeDownload(gen: gen, filename: filename) }
            } catch is CancellationError {
                // cancelDownload() / retryDownload() / stop() own the resulting state.
            } catch {
                Self.onMain { self?.failDownload(gen: gen, error: error) }
            }
        }
    }

    /// Turn a downloader `onProgress(received, total)` tick into a published `DownloadProgress`:
    /// compute pct, and a transfer rate from the delta against the last sample (the rate logic moved
    /// here from the old on-disk poll). Generation-guarded so a superseded download's late callback
    /// can't clobber the current bar. `Date()` is fine in app code.
    private func updateDownloadProgress(gen: Int, file: String, received: Int64, total: Int64) {
        guard downloadGeneration == gen, state == .downloading else { return }
        let now = Date()
        // Rate over a fixed ~0.5 s window: advance the anchor only when the window elapses, so the
        // reading is (bytes over the window) / (window). Sampling per-callback instead pins it to
        // progressStep / main-actor-batch-gap and under-reports ~8x at high throughput.
        var rate = download?.rate  // hold the last reading between window boundaries
        if let anchor = lastDownloadSample {
            let dt = now.timeIntervalSince(anchor.time)
            if dt >= 0.5 {
                if received > anchor.bytes { rate = formatRate(Double(received - anchor.bytes) / dt) }
                lastDownloadSample = (received, now)
            }
        } else {
            lastDownloadSample = (received, now)
        }
        let pct = total > 0 ? min(100, Double(received) / Double(total) * 100) : 0
        download = DownloadProgress(
            pct: pct, file: file, receivedBytes: received, totalBytes: total > 0 ? total : nil,
            rate: rate)
    }

    private func completeDownload(gen: Int, filename: String) {
        guard downloadGeneration == gen else { return }
        endDownloadActivity()
        download = DownloadProgress(pct: 100, file: filename, receivedBytes: 0, totalBytes: nil)
        state = .idle
    }

    private func failDownload(gen: Int, error: Error) {
        guard downloadGeneration == gen else { return }
        endDownloadActivity()
        let detail: String
        switch error {
        case HFDownloader.Failure.http(let code): detail = "HTTP \(code)"
        case HFDownloader.Failure.incompleteAfterRetries: detail = "download interrupted (retries exhausted)"
        case HFDownloader.Failure.invalidFinalFile(let reason): detail = "invalid model file (\(reason))"
        default: detail = (error as NSError).localizedDescription
        }
        state = .error(.downloadFailed(detail: detail))
    }

    private func endDownloadActivity() {
        downloadTask = nil
        downloadProcessLive = false
    }

    /// Cancel whatever download is in flight and start a fresh one — the user's escape hatch from a
    /// stuck/stalled or errored progress bar. The native downloader cancels through the cancelled
    /// task; `download` re-resumes from the on-disk bitmap.
    func retryDownload(variant: Variant, flashQuant: FlashQuant, highPerformance: Bool = false) {
        downloadTask?.cancel()
        downloadTask = nil
        lastDownloadSample = nil
        download = nil
        state = .idle
        download(variant: variant, flashQuant: flashQuant, highPerformance: highPerformance)
    }

    /// Cancel an in-progress download and return to idle without restarting. Bumping the generation
    /// makes the cancelled task's completion callback stale, so it can't flip state to .error.
    func cancelDownload() {
        guard state == .downloading else { return }
        downloadGeneration += 1
        downloadTask?.cancel()
        downloadTask = nil
        // Cancel discards the partial (a deliberate stop, not a pause): remove the sparse `.part`
        // AND its `.part.dl` bitmap sidecar so the next launch's resume check doesn't pick it back
        // up. Quitting mid-download keeps both, so a relaunch resumes from the bitmap.
        if let f = download?.file {
            let base = ggufBaseDir()
            try? FileManager.default.removeItem(at: base.appendingPathComponent(f + ".part"))
            try? FileManager.default.removeItem(at: base.appendingPathComponent(f + ".part.dl"))
        }
        downloadProcessLive = false
        lastDownloadSample = nil
        download = nil
        state = .idle
    }

    /// If a partial download was left by a prior session (the app quit mid-download) and we're idle,
    /// resume it without re-prompting. The native parallel downloader continues from the on-disk
    /// `.part.dl` bitmap (or, for a legacy contiguous `.part`/hf `.incomplete`, from its byte count),
    /// so this is just a normal `download()`. `highPerformance` (the persisted setting) is threaded
    /// through so the resumed download uses the user's chosen worker count.
    func resumeInFlightDownloadIfAny(variant: Variant, flashQuant: FlashQuant, highPerformance: Bool = false) {
        guard state == .idle else { return }
        let base = ggufBaseDir()
        let q = Quant.for(variant, flashQuant: flashQuant)
        // Already fully downloaded → nothing to resume.
        if downloadedModelValidationError(base.appendingPathComponent(q.ggufFilename), quant: q) == nil { return }
        // Resume when the bitmap sidecar records durable bytes (parallel partial), or a legacy
        // contiguous `.part`/hf `.incomplete` has bytes on disk.
        let resumable = resumableBytes(ggufDir: base, filename: q.ggufFilename) > 0
        let legacy = downloadedBytes(ggufDir: base, filename: q.ggufFilename) > 0
        guard resumable || legacy else { return }
        download(variant: variant, flashQuant: flashQuant, highPerformance: highPerformance)
    }

    /// True when the selected variant's gguf exists on disk.
    func isDownloaded(_ variant: Variant, flashQuant: FlashQuant) -> Bool {
        let quant = Quant.for(variant, flashQuant: flashQuant)
        return downloadedModelValidationError(ggufURL(for: variant, flashQuant: flashQuant), quant: quant) == nil
    }

    private func downloadedModelValidationError(_ url: URL, quant: Quant) -> ModelFileValidationError? {
        switch ModelFileValidator.validateGGUF(
            at: url, minimumBytes: ModelFileValidator.minimumBytes(for: quant))
        {
        case .success:
            return nil
        case .failure(let error):
            return error
        }
    }

    // MARK: - Flash quant store (Settings: download markers + cleanup)
    func flashQuantURL(_ q: FlashQuant) -> URL {
        ggufBaseDir().appendingPathComponent(q.quant.ggufFilename)
    }
    func isFlashQuantDownloaded(_ q: FlashQuant) -> Bool {
        FileManager.default.fileExists(atPath: flashQuantURL(q).path)
    }
    /// Delete on-disk Flash quant ggufs other than `keep`. V4 Pro is untouched by construction
    /// (the loop only iterates `FlashQuant`). Gate the call site to idle/error so a loaded or
    /// downloading model is never removed. Returns the removed filenames.
    @discardableResult
    func cleanupUnusedFlashQuants(keep: FlashQuant) -> [String] {
        var removed: [String] = []
        for q in FlashQuant.allCases where q != keep {
            let url = flashQuantURL(q)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                removed.append(q.quant.ggufFilename)
            }
        }
        ggufStoreVersion += 1
        return removed
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
    private nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
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

/// Parse the loaded model's display name from a `/v1/models` response body.
/// ds4 sets each entry's `name` to the actually-loaded model, so prefer it over `id`.
func loadedModelName(from data: Data) -> String? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let arr = obj["data"] as? [[String: Any]], let first = arr.first
    else { return nil }
    return (first["name"] as? String) ?? (first["id"] as? String)
}

/// The loaded server's context window from /v1/models, so a server we ADOPTED (attached to
/// rather than started) reports its real `--ctx` instead of `ctx`'s start-time default.
func loadedContextLength(from data: Data) -> Int? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let arr = obj["data"] as? [[String: Any]], let first = arr.first
    else { return nil }
    return (first["context_length"] as? Int)
        ?? ((first["top_provider"] as? [String: Any])?["context_length"] as? Int)
}
