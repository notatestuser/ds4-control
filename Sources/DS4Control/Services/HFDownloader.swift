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

    /// Coalesce progress callbacks so the UI isn't spammed (~8 MB granularity).
    private static let progressStep: Int64 = 8 * 1024 * 1024
    /// Closed-range chunk size for the parallel path. 256 MB gives fine tail load-balancing across
    /// workers and small crash re-download, while keeping the request count modest (~1800 for the
    /// 464 GB Pro) and each request refreshing the signed URL well within its expiry. Exposed as a
    /// `download` parameter so tests can force many chunks on a small file.
    static let parallelChunkSize: Int64 = 256 * 1024 * 1024

    /// Parallel connection count: a CGNAT-safe 12 by default, an aggressive-but-safe 64 when the
    /// user opts into High Performance (still under the 256 fd soft-limit, with headroom for HF 429).
    static func workerCount(highPerformance: Bool) -> Int { highPerformance ? 64 : 12 }

    init(repo: String, endpoint: String = "https://huggingface.co", revision: String = "main", maxRetries: Int = 8) {
        self.repo = repo
        self.endpoint = endpoint
        self.revision = revision
        self.maxRetries = maxRetries
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

        init(chunkCount: Int, skip: Set<Int>) {
            self.next = 0
            self.count = chunkCount
            self.skip = skip
        }

        /// The number of chunks that still need fetching — used to size the worker pool.
        var remaining: Int { count - skip.count }

        func nextIndex() -> Int? {
            lock.lock()
            defer { lock.unlock() }
            while next < count {
                let i = next
                next += 1
                if !skip.contains(i) { return i }
            }
            return nil
        }
    }

    /// Download `file` into `destDir` with `workerCount(highPerformance:)` parallel chunk connections,
    /// resuming any partial `<file>.part`/`<file>.part.dl` left by a prior run. Returns once the full
    /// file is durably on disk (atomically renamed from `.part`). `onProgress(received, total)` fires
    /// from worker tasks as a single monotonic counter. Throws `CancellationError` if the surrounding
    /// task is cancelled, or `Failure`/the underlying I/O error after exhausting per-chunk retries.
    func download(
        file: String, into destDir: URL, token: String?, highPerformance: Bool,
        chunkSize: Int64 = HFDownloader.parallelChunkSize,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
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
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = workers
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        // Determine TOTAL once: probe `bytes=0-0` into /dev/null (so the probe byte never lands in the
        // .part — chunk 0's real fetch writes offset 0). ChunkFetcher returns the file's total size.
        let devNull = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        defer { try? devNull.close() }
        let probe = ChunkFetcher(session: session)
        let total = try await probe.fetch(
            url: url, offset: 0, end: 0, token: token, fileHandle: devNull, onBytes: { _ in })
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
        // Emit the resume baseline immediately so the UI jumps to the already-downloaded fraction.
        onProgress(progress.received(), total)

        let spawn = min(workers, generator.remaining)
        if spawn > 0 {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for worker in 0..<spawn {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        try await self.runWorker(
                            worker: worker, url: url, token: token, part: part, chunkSize: chunkSize,
                            total: total, session: session, bitmap: bitmap, generator: generator,
                            progress: progress, onProgress: onProgress)
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
        progress: Progress, onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let fetcher = ChunkFetcher(session: session)
        let fh = try FileHandle(forWritingTo: part)
        defer { try? fh.close() }

        while let idx = generator.nextIndex() {
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
                            if let received = progress.addInflight(worker, n) { onProgress(received, total) }
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
            onProgress(progress.commit(worker), total)
        }
    }

    /// Debug-only end-to-end check (env `DS4_SELFTEST_DOWNLOAD=1`): natively stream a few MB of the
    /// real Xet-backed Pro GGUF — exercising resolve → cas-bridge redirect → Range → disk — then
    /// exit OK. Proves the downloader works on the actual file without fetching 430 GB or a GUI.
    static func runSelfTestIfRequested() {
        guard ProcessInfo.processInfo.environment["DS4_SELFTEST_DOWNLOAD"] == "1" else { return }
        let file = "DeepSeek-V4-Pro-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-Instruct-imatrix.gguf"
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
                try await dl.download(file: file, into: dir, token: nil, highPerformance: false) { _, _ in }
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
