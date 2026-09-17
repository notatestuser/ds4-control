import Foundation

/// Streams a Hugging Face repo file over plain HTTPS — no `hf` CLI, no curl. The model GGUFs are
/// Xet-backed: `…/resolve/<rev>/<file>` 302-redirects to a signed `cas-bridge.xethub.hf.co` URL.
/// `URLSession` follows that redirect and re-applies our `Range` header, and the bridge honours
/// range requests (HTTP 206).
///
/// This downloads in PARALLEL: N workers each fetch a fixed-size closed range straight to its offset
/// in `<file>.part`, with a `ChunkBitmap` sidecar (`<file>.part.dl`) recording durably-complete
/// chunks. Because the writes are out-of-order the `.part` is *sparse* (file size ≠ bytes fetched),
/// so progress comes from the bitmap + in-flight byte counters (the `onProgress` callback), not the
/// file size. Resume across launches re-reads the bitmap and only refetches the chunks it lacks
/// (idempotent — a refetched chunk overwrites the same offset). Each chunk re-hits `/resolve`, so
/// the signed-URL ~1 h expiry never bites a multi-hour download.
///
/// Honours Swift task cancellation: cancelling the surrounding `Task` cancels every in-flight chunk.
final class HFDownloader: NSObject, @unchecked Sendable {
    enum Failure: Error, Equatable { case http(Int), incompleteAfterRetries }

    private let repo: String
    private let endpoint: String
    private let revision: String
    private let maxRetries: Int
    /// Injected by tests to route through a mock `URLProtocol`; production uses `.default`.
    private let sessionConfiguration: URLSessionConfiguration?
    /// Backoff base between probe attempts (tests shrink it).
    private let probeRetryBackoff: TimeInterval
    /// Ramp measurement-window floor (tests shrink it for small files).
    private let minRampWindow: TimeInterval
    /// Cooldown between a settled ramp's one-promotion probes (tests shrink it).
    private let rampRearmInterval: TimeInterval

    /// Coalesce progress callbacks so the UI isn't spammed (~8 MB granularity).
    private static let progressStep: Int64 = 8 * 1024 * 1024
    /// Closed-range chunk size for the parallel path. 256 MB gives fine tail load-balancing across
    /// workers and small crash re-download, while keeping the request count modest (~1800 for the
    /// 464 GB Pro) and each request refreshing the signed URL well within its expiry. Exposed as a
    /// `download` parameter so tests can force many chunks on a small file.
    static let parallelChunkSize: Int64 = 256 * 1024 * 1024

    /// Worker-count bounds: the CGNAT-safe base (8) that every download starts at, and the
    /// opt-in aggressive ceiling (64) that High Performance ramps toward while throughput
    /// improves. Also keeps us under the 256 fd soft-limit, with headroom for HF 429.
    static func workerCount(highPerformance: Bool) -> Int { highPerformance ? 64 : 8 }

    init(
        repo: String, endpoint: String = "https://huggingface.co", revision: String = "main", maxRetries: Int = 8,
        sessionConfiguration: URLSessionConfiguration? = nil, probeRetryBackoff: TimeInterval = 1.0,
        minRampWindow: TimeInterval = 8, rampRearmInterval: TimeInterval = 300
    ) {
        self.repo = repo
        self.endpoint = endpoint
        self.revision = revision
        self.maxRetries = maxRetries
        self.sessionConfiguration = sessionConfiguration
        // Sanitized at the boundary: this knob exists for tests, and a negative, non-finite, or
        // gigantic value would otherwise trap the UInt64 nanosecond conversion in the probe retry.
        self.probeRetryBackoff = probeRetryBackoff.isFinite ? min(max(probeRetryBackoff, 0), 60) : 0
        self.minRampWindow = minRampWindow.isFinite ? min(max(minRampWindow, 0), 30) : 8
        self.rampRearmInterval =
            rampRearmInterval.isFinite ? min(max(rampRearmInterval, 0), 3600) : 300
        super.init()
    }

    /// Lock-guarded byte accumulator shared by every worker. Each worker reports its in-flight bytes
    /// into its own slot; `received` = durably-completed bytes + Σ in-flight, clamped to `total`.
    /// Methods return a coalesced `received` (≥ the ~8 MB step since the last report) to emit, or nil
    /// when nothing material changed — so the UI sees a single monotonic counter despite N writers.
    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private let total: Int64
        private var completedBytes: Int64
        private var inflight: [Int64]
        private var lastReported: Int64

        init(completedBytes: Int64, workerCount: Int, total: Int64) {
            self.total = total
            self.completedBytes = completedBytes
            self.inflight = [Int64](repeating: 0, count: max(workerCount, 1))
            self.lastReported = completedBytes
        }

        /// The current monotonic received count (completed + all in-flight), clamped to total.
        private func receivedLocked() -> Int64 {
            min(completedBytes + inflight.reduce(0, +), total)
        }

        /// Add `n` freshly-received bytes to `worker`'s in-flight tally; return a value to emit only
        /// when the received count crossed the ~8 MB report step since the last emit, else nil.
        func addInflight(_ worker: Int, _ n: Int64) -> Int64? {
            lock.lock()
            defer { lock.unlock() }
            inflight[worker] += n
            let received = receivedLocked()
            if received - lastReported >= HFDownloader.progressStep {
                lastReported = received
                return received
            }
            return nil
        }

        /// Promote `worker`'s in-flight bytes to durably-complete (its chunk finished + fsynced) and
        /// reset its slot. Always returns the new received count so completion is reported promptly.
        func commit(_ worker: Int) -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            completedBytes += inflight[worker]
            inflight[worker] = 0
            let received = receivedLocked()
            lastReported = received
            return received
        }

        /// Drop `worker`'s in-flight bytes without committing them — used before a chunk retry so the
        /// previous attempt's partial bytes aren't double-counted when the refetch re-streams them.
        func discard(_ worker: Int) {
            lock.lock()
            defer { lock.unlock() }
            inflight[worker] = 0
        }

        /// The received count for the initial one-shot emit at start.
        func received() -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            return receivedLocked()
        }
    }

    /// Lock-guarded generator that hands each not-yet-complete chunk index to exactly one worker.
    /// Seeded to skip the indices the bitmap already has, so resume only fetches what's missing.
    private final class ChunkIndexGenerator: @unchecked Sendable {
        private let lock = NSLock()
        private var next: Int
        private let count: Int
        private let skip: Set<Int>
        private var handedOut = 0

        init(chunkCount: Int, skip: Set<Int>) {
            self.next = 0
            self.count = chunkCount
            self.skip = skip
        }

        /// The number of chunks that still need fetching — used to size the worker pool.
        var remaining: Int { count - skip.count }

        /// True once every outstanding index has been handed to a worker: the ramp controller's
        /// stop condition (the pool then only drains what is already in flight).
        var allHandedOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return handedOut >= count - skip.count
        }

        func nextIndex() -> Int? {
            lock.lock()
            defer { lock.unlock() }
            while next < count {
                let i = next
                next += 1
                if !skip.contains(i) {
                    handedOut += 1
                    return i
                }
            }
            return nil
        }
    }

    /// Lock-guarded task state shared by the ramp controller and workers. Worker slots are reused
    /// after a backed-off task exits so their indices always remain valid `Progress` slots. Workers
    /// only report completion/failure here; the controller remains the sole task-group mutator.
    private final class WorkerPoolState: @unchecked Sendable {
        private let lock = NSLock()
        private let cap: Int
        private var live: Set<Int> = []
        private var firstFailure: (any Error)?

        init(cap: Int) {
            self.cap = max(cap, 1)
        }

        /// Atomically reserve every vacant slot below `desired` before the controller spawns it.
        func reserve(upTo desired: Int) -> [Int] {
            lock.lock()
            defer { lock.unlock() }
            guard firstFailure == nil else { return [] }
            let limit = min(max(desired, 0), cap)
            let workers = (0..<limit).filter { !live.contains($0) }
            live.formUnion(workers)
            return workers
        }

        func finish(_ worker: Int, failure: (any Error)? = nil) {
            lock.lock()
            defer { lock.unlock() }
            live.remove(worker)
            if firstFailure == nil, let failure {
                firstFailure = failure
            }
        }

        var hasFailure: Bool {
            lock.lock()
            defer { lock.unlock() }
            return firstFailure != nil
        }
    }

    /// Length of one ramp measurement window: long enough for ~2 chunks at the current rate so a
    /// window's rate isn't dominated by chunk-boundary quantization, floored at `minWindow` (8 s
    /// production; tests lower it for small files) and capped so a slow path can't stall the ramp.
    static func rampWindowSeconds(
        rate: Double, chunkSize: Int64, minWindow: TimeInterval = 8
    ) -> TimeInterval {
        let seconds = rate > 0 ? (2 * Double(chunkSize)) / rate : minWindow
        return min(30, max(minWindow, seconds))
    }

    /// Download `file` into `destDir` with `workerCount(highPerformance:)` parallel chunk connections,
    /// resuming any partial `<file>.part`/`<file>.part.dl` left by a prior run. Returns once the full
    /// file is durably on disk (atomically renamed from `.part`). `onProgress(received, total,
    /// connections)` fires from worker tasks as a single monotonic counter, with the live pool size
    /// so the UI can show how many connections the download is using. Throws `CancellationError` if
    /// the surrounding task is cancelled, or `Failure`/the underlying I/O error after exhausting
    /// per-chunk retries.
    func download(
        file: String, into destDir: URL, token: String?, highPerformance: Bool,
        chunkSize: Int64 = HFDownloader.parallelChunkSize,
        onProgress: @escaping @Sendable (Int64, Int64, Int) -> Void
    ) async throws {
        let dest = destDir.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: dest.path) { return }
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let part = destDir.appendingPathComponent(file + ".part")
        let url = URL(string: "\(endpoint)/\(repo)/resolve/\(revision)/\(file)")!
        let workers = Self.workerCount(highPerformance: highPerformance)

        // ONE shared session for all workers. CRITICAL: httpMaximumConnectionsPerHost defaults to 6,
        // which would silently cap parallelism — raise it to the worker count. With per-task delegates
        // (set inside each ChunkFetcher) the session needs no session-wide delegate.
        let base = sessionConfiguration ?? URLSessionConfiguration.default
        // Copy before mutating: an injected configuration may be shared across downloads, and this
        // download owns its session settings — a borrowed instance must never be altered.
        let cfg = (base.copy() as? URLSessionConfiguration) ?? base
        cfg.timeoutIntervalForRequest = 60
        // Fail fast instead of parking in `.waitingForConnectivity`: that wait is unbounded, so a
        // first-contact network blip froze the whole download on a spinner with no speed (the
        // probe never returned and no worker ever started). Transient failures are absorbed by the
        // probe retry below and the workers' per-chunk backoff; a persistent outage surfaces as an
        // error banner, and Retry resumes from the bitmap.
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = workers
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        // Determine TOTAL once: probe `bytes=0-0` into /dev/null (so the probe byte never lands in the
        // .part — chunk 0's real fetch writes offset 0). ChunkFetcher returns the file's total size.
        let devNull = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        defer { try? devNull.close() }
        // Size probe, retried: it is the FIRST network contact (cold DNS/route, VPN churn), and the
        // workers' resilient path doesn't start until it returns. Capped at 3 attempts so a
        // persistently unreachable server fails the download instead of spinning forever. A fresh
        // fetcher per attempt: the failed task's async cancellation completion must never resume
        // the retry's continuation (a reused fetcher's `finish` can't tell the tasks apart).
        var probeTotal: Int64 = -1
        var probeAttempt = 0
        while true {
            do {
                probeTotal = try await ChunkFetcher(session: session).fetch(
                    url: url, offset: 0, end: 0, token: token, fileHandle: devNull, onBytes: { _ in })
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                probeAttempt += 1
                if probeAttempt >= 3 { throw error }
                try await Task.sleep(
                    nanoseconds: UInt64(Double(probeAttempt) * probeRetryBackoff * 1_000_000_000))
            }
        }
        let total = probeTotal  // immutable from here so the worker closures capture a let
        guard total > 0 else { throw Failure.http(-1) }

        // Migration: a legacy *sequential* `.part` (contiguous, no sidecar) has its leading whole
        // chunks already on disk — seed the bitmap so we don't refetch them. If a sidecar already
        // exists, loadOrCreate adopts it and ignores this seed. Pass 0 when there's no .part.
        let sidecarExists = FileManager.default.fileExists(atPath: part.path + ".dl")
        let legacyBytes: Int64 =
            (!sidecarExists && FileManager.default.fileExists(atPath: part.path))
            ? Int64((try? FileHandle(forReadingFrom: part).seekToEnd()) ?? 0) : 0

        // Ensure the .part exists, then preallocate it to `total` — parallel offset writes land beyond
        // the current EOF, so the file must be sized up front (truncate grows it, sparse).
        if !FileManager.default.fileExists(atPath: part.path) {
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        let bitmap = try ChunkBitmap.loadOrCreate(
            partURL: part, total: total, chunkSize: chunkSize, seedContiguousBytes: legacyBytes)
        do {
            let sizer = try FileHandle(forWritingTo: part)
            try sizer.truncate(atOffset: UInt64(total))
            try sizer.close()
        }

        let progress = Progress(completedBytes: bitmap.completedBytes(), workerCount: workers, total: total)
        let generator = ChunkIndexGenerator(chunkCount: bitmap.chunkCount, skip: bitmap.completedIndices())

        // Every download starts at the CGNAT-safe base; High Performance ramps toward the cap
        // while measured throughput improves (see WorkerRamp — starting wide is what stalled a
        // real 64-connection run over a lossy tunnel).
        let capWorkers = workers
        let baseWorkers = min(workers, HFDownloader.workerCount(highPerformance: false))
        let ramp = WorkerRamp(start: baseWorkers, cap: capWorkers)
        let workerPool = WorkerPoolState(cap: capWorkers)
        // Emit the resume baseline immediately so the UI jumps to the already-downloaded fraction.
        onProgress(progress.received(), total, ramp.allowed)
        let initial = min(ramp.allowed, generator.remaining)
        if initial > 0 {
            try await withThrowingTaskGroup(of: Void.self) { group in
                func addWorkers(upTo desired: Int) {
                    for worker in workerPool.reserve(upTo: desired) {
                        group.addTask {
                            do {
                                try await self.runWorker(
                                    worker: worker, url: url, token: token, part: part,
                                    chunkSize: chunkSize, total: total, session: session,
                                    bitmap: bitmap, generator: generator, ramp: ramp,
                                    progress: progress, onProgress: onProgress)
                                workerPool.finish(worker)
                            } catch {
                                workerPool.finish(worker, failure: error)
                                throw error
                            }
                        }
                    }
                }
                addWorkers(upTo: initial)
                if capWorkers > baseWorkers {
                    // Adaptive ramp: sample durable bytes per window and grow the pool only while
                    // the rate improves; the first window that doesn't settles back at the best
                    // count (extra workers exit at their chunk boundary via `ramp.allows`). A
                    // settled ramp re-arms after `rampRearmInterval` with one promotion, so a
                    // recovering path is exploited instead of staying at the backed-off count.
                    var lastCompleted = bitmap.completedBytes()
                    var lastSample = Date()
                    var nextProbeAt: Date? = nil
                    while !generator.allHandedOut {
                        if workerPool.hasFailure { break }
                        let now = Date()
                        let completed = bitmap.completedBytes()
                        let elapsed = max(now.timeIntervalSince(lastSample), 0.001)
                        let rate = Double(completed - lastCompleted) / elapsed
                        lastCompleted = completed
                        lastSample = now
                        let window = HFDownloader.rampWindowSeconds(
                            rate: rate, chunkSize: chunkSize, minWindow: minRampWindow)

                        if ramp.settled, ramp.allowed >= ramp.cap {
                            try await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
                            continue  // nothing left to probe at the cap
                        }
                        if ramp.settled {
                            if let probeAt = nextProbeAt, now < probeAt {
                                try await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
                                continue  // cooldown: hold the backed-off count
                            }
                            let before = ramp.allowed
                            let next = ramp.startProbe()
                            addWorkers(upTo: next)
                            if next != before { onProgress(progress.received(), total, next) }
                            nextProbeAt =
                                next < ramp.cap
                                ? now.addingTimeInterval(rampRearmInterval) : nil
                        } else {
                            let before = ramp.allowed
                            let next = ramp.observe(rate: rate)
                            addWorkers(upTo: next)
                            if next != before { onProgress(progress.received(), total, next) }
                            if ramp.settled {
                                nextProbeAt =
                                    ramp.allowed < ramp.cap
                                    ? now.addingTimeInterval(rampRearmInterval) : nil
                            }
                        }
                        try await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
                    }
                }
                // Propagate the first worker failure (or cancellation) to the rest.
                try await group.waitForAll()
            }
        }

        // All chunks durable: fsync the assembled .part, drop the sidecar, atomic rename → final.
        let finalize = try FileHandle(forWritingTo: part)
        try finalize.synchronize()
        try finalize.close()
        bitmap.delete()
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: part, to: dest)
    }

    /// One worker: its OWN `ChunkFetcher` + its OWN `FileHandle` on the `.part` (a separate FD, so
    /// concurrent non-overlapping offset writes are safe — never share a single handle across
    /// workers). Pulls chunk indices from the shared generator until exhausted, fetching each with a
    /// per-chunk retry/backoff that mirrors the old sequential loop: a fetch that makes progress
    /// resets the retry budget; otherwise back off (capped, with a little startup jitter to avoid all
    /// workers hammering at once) and refetch the same idempotent range.
    private func runWorker(
        worker: Int, url: URL, token: String?, part: URL, chunkSize: Int64, total: Int64,
        session: URLSession, bitmap: ChunkBitmap, generator: ChunkIndexGenerator,
        ramp: WorkerRamp, progress: Progress,
        onProgress: @escaping @Sendable (Int64, Int64, Int) -> Void
    ) async throws {
        let fetcher = ChunkFetcher(session: session)
        let fh = try FileHandle(forWritingTo: part)
        defer { try? fh.close() }

        // Check the ramp BEFORE pulling: a worker the ramp backed away from exits at its chunk
        // boundary and leaves every index it hasn't taken for the workers that remain.
        while ramp.allows(worker) {
            guard let idx = generator.nextIndex() else { break }
            try Task.checkCancellation()
            let offset = Int64(idx) * chunkSize
            let end = min(offset + chunkSize - 1, total - 1)
            var attempt = 0
            while true {
                try Task.checkCancellation()
                try fh.seek(toOffset: UInt64(offset))
                progress.discard(worker)  // drop any partial bytes from a previous failed attempt.
                do {
                    _ = try await fetcher.fetch(
                        url: url, offset: offset, end: end, token: token, fileHandle: fh,
                        onBytes: { n in
                            if let received = progress.addInflight(worker, n) {
                                onProgress(received, total, ramp.allowed)
                            }
                        })
                    break  // chunk delivered fully (ChunkFetcher rejects short reads).
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // No progress made → spend a retry; throw once the budget is exhausted. (Unlike
                    // the sequential path we can't cheaply tell partial-progress here, so each chunk
                    // simply gets the full retry budget — fine since chunks are small.)
                    attempt += 1
                    if attempt > maxRetries { throw Failure.incompleteAfterRetries }
                    // backoff: 1,2,…,5,5… seconds + up to 1s jitter so workers don't sync-hammer.
                    let backoff = min(max(attempt, 1), 5)
                    let jitterNs = UInt64.random(in: 0...1_000_000_000)
                    try await Task.sleep(nanoseconds: UInt64(backoff) * 1_000_000_000 + jitterNs)
                }
            }
            // Durable: fsync the .part, flip the bitmap bit (which fsyncs the sidecar), then promote
            // this chunk's bytes from in-flight to completed and report.
            try fh.synchronize()
            try bitmap.markComplete(idx)
            onProgress(progress.commit(worker), total, ramp.allowed)
        }
    }

    /// Debug-only end-to-end check (env `DS4_SELFTEST_DOWNLOAD=1`): natively stream a few MB of the
    /// real Xet-backed Pro GGUF — exercising resolve → cas-bridge redirect → Range → disk — then
    /// exit OK. Proves the downloader works on the actual file without fetching 430 GB or a GUI.
    static func runSelfTestIfRequested() {
        guard ProcessInfo.processInfo.environment["DS4_SELFTEST_DOWNLOAD"] == "1" else { return }
        let file = "DeepSeek-V4-Pro-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-Instruct-imatrix-0813.gguf"
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ds4-dltest-\(UUID().uuidString)")
        let dl = HFDownloader(repo: "antirez/deepseek-v4-gguf")
        let err: @Sendable (String) -> Never = { msg in
            FileHandle.standardError.write(Data("DS4_SELFTEST_DOWNLOAD: FAIL — \(msg)\n".utf8))
            try? FileManager.default.removeItem(at: dir)
            exit(1)
        }
        let task = Task {
            do {
                try await dl.download(file: file, into: dir, token: nil, highPerformance: false) { _, _, _ in }
            } catch is CancellationError {
            } catch { err("\(error)") }
        }
        Task {
            let deadline = Date().addingTimeInterval(45)
            while true {
                try? await Task.sleep(nanoseconds: 200_000_000)
                // The .part is preallocated to the full size, so its file size is meaningless here;
                // the bitmap's completed bytes are the real signal that chunks are landing.
                let done = resumableBytes(ggufDir: dir, filename: file)
                if done >= 8_000_000 {
                    task.cancel()
                    FileHandle.standardError.write(
                        Data("DS4_SELFTEST_DOWNLOAD: OK — \(done) bytes streamed natively from Xet\n".utf8))
                    try? FileManager.default.removeItem(at: dir)
                    exit(0)
                }
                if Date() > deadline { err("timeout at \(done) bytes") }
            }
        }
        dispatchMain()
    }
}

/// Adaptive worker-count policy for High Performance downloads: begin at the CGNAT-safe base,
/// double toward the cap while a measurement window beats the best rate by ≥10%, and on the first
/// window that fails to improve (or stalls) settle back at the best-observed count. The controller
/// re-arms a settled ramp after a cooldown with ONE promotion probe, so a recovering path is
/// exploited instead of staying backed off. Starting wide is what stalled a real download at 64
/// connections over a lossy tunnel; the ramp keeps the aggressive ceiling for healthy paths without
/// racing into congestion.
final class WorkerRamp: @unchecked Sendable {
    static let improvementMargin = 1.10
    /// Ramping is judging windows and may grow; settled is holding at the best count (the
    /// controller re-arms a probe after its cooldown); probing is the one promotion tried then.
    enum Phase { case ramping, settled, probing }
    private let lock = NSLock()
    let cap: Int
    private var _allowed: Int
    private var bestRate: Double = 0
    private var bestAllowed: Int
    private var _phase: Phase = .ramping

    init(start: Int, cap: Int) {
        self.cap = max(1, cap)
        self._allowed = max(1, min(start, self.cap))
        self.bestAllowed = self._allowed
    }

    /// Whether `worker` may pull more chunks. Checked before each handout, so workers the
    /// ramp backed away from exit at their chunk boundary instead of competing on.
    func allows(_ worker: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return worker < _allowed
    }

    var allowed: Int {
        lock.lock()
        defer { lock.unlock() }
        return _allowed
    }

    var settled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _phase == .settled
    }

    /// Feed one measurement window's aggregate rate (bytes/s); returns the count to allow next.
    @discardableResult
    func observe(rate: Double) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if rate <= 0 {
            // A stalled window must never grow the pool; once a baseline exists it ends the attempt.
            if bestRate > 0, _phase != .settled {
                _allowed = bestAllowed
                _phase = .settled
            }
            return _allowed
        }
        switch _phase {
        case .settled:
            return _allowed  // only the controller's re-arm starts growth again
        case .probing:
            if rate > bestRate * Self.improvementMargin {
                bestRate = rate
                bestAllowed = _allowed
                _phase = .ramping  // the path recovered: keep the probe and resume growing
            } else {
                _allowed = bestAllowed
                _phase = .settled  // the probe failed: back to the best, wait for the next re-arm
            }
            return _allowed
        case .ramping:
            if bestRate == 0 {
                // First window: establish the baseline, then try more connections.
                bestRate = rate
                bestAllowed = _allowed
                _allowed = min(cap, _allowed * 2)
                return _allowed
            }
            if _allowed >= cap {
                // At the cap: hold it on improvement; the first window that fails to improve
                // settles back at the best count.
                if rate > bestRate * Self.improvementMargin {
                    bestRate = rate
                    bestAllowed = _allowed
                } else {
                    _allowed = bestAllowed
                }
                _phase = .settled
                return _allowed
            }
            if rate > bestRate * Self.improvementMargin {
                bestRate = rate
                bestAllowed = _allowed
                _allowed = min(cap, _allowed * 2)
            } else {
                // First window that failed to improve: back to the best count and hold.
                _allowed = bestAllowed
                _phase = .settled
            }
            return _allowed
        }
    }

    /// The controller's re-arm after the cooldown: probe ONE promotion from the settled count.
    /// Returns the count to allow (unchanged at the cap or if the ramp isn't settled).
    @discardableResult
    func startProbe() -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard _phase == .settled, _allowed < cap else { return _allowed }
        _phase = .probing
        _allowed = min(cap, _allowed * 2)
        return _allowed
    }
}
