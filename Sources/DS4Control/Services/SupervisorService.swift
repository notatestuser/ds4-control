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
    private var downloadPollTimer: Timer?
    private var lastDownloadSample: (bytes: Int64, time: Date)?
    /// True when tracking a download started by a previous session (we poll its
    /// .incomplete file but don't own the process — see resumeInFlightDownloadIfAny).
    private var downloadAttached = false
    private var staleDownloadPolls = 0
    /// True when attached to a ds4-server started by a previous session (we don't
    /// own the process; Stop terminates it by port — see resumeRunningServerIfAny).
    private var serverAttached = false
    /// Deferred start used by `restart`: when stopping an owned process, the relaunch
    /// can't happen until it has fully exited (port freed). `handleExit` runs this.
    private var pendingRestart: (() -> Void)?

    init(
        ds4Dir: URL, runner: ProcessRunner, serverProbe: ((Int) async -> Data?)? = nil,
        downloadRunner: ProcessRunner? = nil
    ) {
        self.ds4Dir = ds4Dir
        self.runner = runner
        self.serverProbe = serverProbe ?? SupervisorService.defaultServerProbe
        self.downloadRunner = downloadRunner ?? RealProcessRunner()
    }

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
    /// Disk KV-cache budget (MB) when `kvDiskDir` is provided. ds4's compressed KV
    /// is tiny, so this holds many cached prefixes; generous but trivial on modern SSDs.
    static let kvDiskSpaceMB = 32768

    func start(variant: Variant, ctx: Int, port: Int, power: Int?, kvDiskDir: URL? = nil) {
        guard state == .idle || isErrorState else { emitBadState("start"); return }
        if let e = validateDs4Dir() { state = .error(e); return }
        let ram = systemRamGiB()
        let gguf = ggufURL(for: variant, ramGiB: ram)
        guard FileManager.default.fileExists(atPath: gguf.path) else {
            state = .error(.modelMissing(filename: gguf.lastPathComponent)); return
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
    func restart(variant: Variant, ctx: Int, port: Int, power: Int?, kvDiskDir: URL? = nil) {
        guard state == .ready || state == .starting else { emitBadState("restart"); return }
        let relaunch: () -> Void = { [weak self] in
            guard let self else { return }
            self.start(variant: variant, ctx: ctx, port: port, power: power, kvDiskDir: kvDiskDir)
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

    func download(variant: Variant, highPerformance: Bool = false) {
        guard state == .idle || isErrorState else { emitBadState("download"); return }
        if let e = validateDs4Dir() { state = .error(e); return }
        let q = Quant.for(variant, ramGiB: systemRamGiB())
        let baseDir = ggufBaseDir()
        let expectedBytes = Int64(q.weightsGiB * 1_073_741_824)
        download = DownloadProgress(pct: 0, file: q.ggufFilename, receivedBytes: 0, totalBytes: expectedBytes)
        state = .downloading
        downloadAttached = false
        downloadGeneration += 1
        let gen = downloadGeneration
        // Progress comes from polling the file on disk: the hf downloader emits no
        // parseable progress to a non-TTY pipe, so stderr-parsing alone stays at 0%.
        startDownloadPolling(baseDir: baseDir, filename: q.ggufFilename, expected: expectedBytes)
        let buf = DownloadStderrBuffer()
        let args = [q.arg]
        // Optional auth: pass any HF_TOKEN (env or hf cache) to the child via the
        // environment so hf can authenticate — never on the command line (no ps leak).
        var env: [String: String] = [:]
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/token")
        if let token = resolveHFToken(env: ProcessInfo.processInfo.environment, cacheFile: cache) {
            env["HF_TOKEN"] = token
        }
        // Default: cap Xet's parallel range-GETs. Its adaptive concurrency otherwise opens
        // 35+ connections, exhausting a carrier-grade NAT session table and tripping a
        // ~15-min cooldown; a small reused pool stays well under CGNAT limits. High-performance
        // mode (Settings, default off) lets it run wide for max throughput on uncapped links.
        if highPerformance {
            env["HF_XET_HIGH_PERFORMANCE"] = "1"
        } else {
            env["HF_XET_FIXED_DOWNLOAD_CONCURRENCY"] = "10"
            env["HF_XET_CLIENT_AC_MAX_DOWNLOAD_CONCURRENCY"] = "10"
        }
        do {
            try downloadRunner.launch(
                executable: ds4Dir.appendingPathComponent("download_model.sh"),
                args: args, cwd: ds4Dir, env: env,
                onStderrLine: { [weak self] line in
                    buf.text += line + "\n"
                    if buf.text.count > 4096 { buf.text = String(buf.text.suffix(2048)) }
                    // parseCurlProgress now ignores hf's premature "Fetching N files: 100%"
                    // (it requires a byte-size token); the on-disk poll is the backstop.
                    guard let pct = parseCurlProgress(buf.text) else { return }
                    let rate = parseDownloadRate(buf.text)
                    Self.onMain {
                        guard let self, self.downloadGeneration == gen else { return }
                        self.download = DownloadProgress(
                            pct: pct, file: q.ggufFilename, receivedBytes: 0, totalBytes: nil, rate: rate)
                    }
                },
                onExit: { [weak self] code in
                    Self.onMain {
                        guard let self, self.downloadGeneration == gen else { return }
                        self.downloadProcessLive = false
                        self.downloadPollTimer?.invalidate()
                        self.downloadPollTimer = nil
                        if code == 0 {
                            self.download = DownloadProgress(
                                pct: 100, file: q.ggufFilename, receivedBytes: 0, totalBytes: nil)
                            self.state = .idle
                        } else {
                            let tail = String(buf.text.suffix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
                            self.state = .error(.downloadFailed(detail: tail.isEmpty ? "exit \(code)" : tail))
                        }
                    }
                })
            downloadProcessLive = true
        } catch {
            downloadPollTimer?.invalidate()
            downloadPollTimer = nil
            downloadProcessLive = false
            state = .error(.downloadFailed(detail: "\(error)"))
        }
    }

    /// Cancel whatever download is being tracked (owned process or an attached
    /// orphan) and start a fresh one — the user's escape hatch from a stuck/stalled
    /// or errored progress bar.
    func retryDownload(variant: Variant, highPerformance: Bool = false) {
        downloadRunner.terminate(graceSeconds: 0)  // no-op if nothing is running
        downloadPollTimer?.invalidate()
        downloadPollTimer = nil
        downloadAttached = false
        lastDownloadSample = nil
        download = nil
        state = .idle
        download(variant: variant, highPerformance: highPerformance)
    }

    /// Cancel an in-progress download and return to idle without restarting. Bumping the
    /// generation makes the killed process's exit callback stale, so it can't flip state to
    /// .error. An owned download is tree-killed via the runner; an attached one (resumed
    /// from a prior session, so we hold no Process) is stopped by killing the matching ds4
    /// download processes — the pattern hits both the shell and `hf`, so neither orphans.
    func cancelDownload() {
        guard state == .downloading else { return }
        downloadGeneration += 1
        if downloadAttached {
            killAttachedDownloadProcesses()
        } else {
            downloadRunner.terminate(graceSeconds: 0)
        }
        downloadPollTimer?.invalidate()
        downloadPollTimer = nil
        downloadAttached = false
        downloadProcessLive = false
        lastDownloadSample = nil
        staleDownloadPolls = 0
        download = nil
        state = .idle
    }

    private func killAttachedDownloadProcesses() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "download_model|deepseek-v4-gguf"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
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
        downloadProcessLive = isDownloadProcessRunning()
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
            downloadProcessLive = false
            downloadPollTimer?.invalidate()
            downloadPollTimer = nil
            return
        }
        // Liveness for the spinner: our own process, or (when attached) one pgrep finds.
        // `isRunning` short-circuits for owned downloads, so pgrep only runs when attached.
        downloadProcessLive = downloadRunner.isRunning || isDownloadProcessRunning()
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
        downloadProcessLive = false
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
