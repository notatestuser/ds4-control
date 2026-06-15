import Foundation

/// Downloads ONE closed byte-range of a Hugging Face repo file straight to a caller-supplied
/// `FileHandle` at a given offset, over a *shared* `URLSession` (so N of these run in parallel on one
/// connection pool). It mirrors `HFDownloader`'s single-range delegate logic but holds per-chunk
/// state that is reset on every `fetch` call, and uses a *per-task* delegate (`task.delegate = self`,
/// macOS 13+) so many fetchers can share one session without fighting over a single session-wide
/// delegate.
///
/// The caller owns the `.part` file, the `Range`/closed-chunk policy, the chunk bitmap, and the retry
/// loop — this type just streams one range and reports bytes. It is deliberately *not* responsible
/// for backoff: 429/503 surface as `HFDownloader.Failure.http` so the caller's retry loop can decide
/// to wait and re-fetch the same chunk (idempotent: same offset, overwritten).
///
/// Honours Swift task cancellation: cancelling the surrounding `Task` cancels the in-flight request.
final class ChunkFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// The shared session, configured (and owned) by the caller — notably its
    /// `httpMaximumConnectionsPerHost`, which gates real parallelism.
    private let session: URLSession
    private let lock = NSLock()

    // Per-fetch state. Written only on the session's serial delegate queue and read after the attempt
    // completes, with a happens-before edge through the continuation resume. Reset at the top of every
    // `fetch` so a reused `ChunkFetcher` instance never carries a previous chunk's counters.
    private var activeTaskIdentifier: Int?
    private var handle: FileHandle?
    /// The `Range` of the in-flight attempt, re-applied across the cas-bridge redirect.
    private var currentRange: String?
    /// `end - offset + 1`: how many bytes a correct 206 must deliver for this chunk.
    private var expectedLength: Int64 = 0
    /// Bytes actually written for this chunk — checked against `expectedLength` at completion.
    private var writtenThisChunk: Int64 = 0
    /// Total final-file size parsed from the first 206's `Content-Range: a-b/total`; -1 until seen.
    private var total: Int64 = -1
    private var onBytes: ((Int64) -> Void)?
    private var cont: CheckedContinuation<Void, Error>?

    init(session: URLSession) {
        self.session = session
        super.init()
    }

    /// Download the closed range `offset…end` of `url` to `fileHandle` (which the caller has already
    /// `seek(toOffset: offset)`d). Reports each received block's size via `onBytes`. Returns the
    /// file's TOTAL size, parsed from the 206 `Content-Range`. Throws `CancellationError` if the task
    /// is cancelled, or `HFDownloader.Failure`/the underlying I/O error otherwise.
    ///
    /// `end` is INCLUSIVE — the cas-bridge 400s an open-ended `bytes=offset-`, so the range must be
    /// closed. A short clean completion (fewer than `expectedLength` bytes) is treated as a failure,
    /// not success, so the caller's retry loop re-fetches rather than marking a partial chunk done.
    func fetch(
        url: URL, offset: Int64, end: Int64, token: String?, fileHandle: FileHandle,
        onBytes: @escaping (Int64) -> Void
    ) async throws -> Int64 {
        var req = URLRequest(url: url)
        let range = "bytes=\(offset)-\(end)"
        req.setValue(range, forHTTPHeaderField: "Range")
        if let token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let task = session.dataTask(with: req)
        task.delegate = self  // per-task delegate so many fetchers share one session (macOS 13+).
        lock.withLock {
            activeTaskIdentifier = task.taskIdentifier
            handle = fileHandle
            self.onBytes = onBytes
            expectedLength = end - offset + 1
            writtenThisChunk = 0
            total = -1
            cont = nil
            currentRange = range
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                self.lock.lock()
                self.cont = c
                self.lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return lock.withLock { total }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // huggingface.co `/resolve` 302s to a *pre-signed* cas-bridge URL. URLSession otherwise drops
        // our Range across the redirect → it would serve the WRONG bytes (the whole file from 0), so
        // re-apply it. Strip Authorization — the signed URL needs none, and forwarding the token
        // cross-host breaks the S3 signature.
        guard let currentRange = currentRange(for: task) else {
            completionHandler(nil)
            return
        }
        var req = request
        req.setValue(currentRange, forHTTPHeaderField: "Range")
        req.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(req)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard isCurrent(task: dataTask) else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            finish(for: dataTask, .failure(HFDownloader.Failure.http(-1)))
            completionHandler(.cancel)
            return
        }
        // 429 (rate limited) / 503 (unavailable) are RETRYABLE — surface them as Failure.http so the
        // caller's retry loop backs off and re-fetches; any other non-2xx is a hard failure for this
        // chunk. Either way we cancel the task.
        guard http.statusCode == 206 else {
            finish(for: dataTask, .failure(HFDownloader.Failure.http(http.statusCode)))
            completionHandler(.cancel)
            return
        }
        lock.lock()
        if total < 0 { total = Self.parseTotal(http, fallbackOffset: writtenThisChunk) }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard isCurrentLocked(task: dataTask), let handle else {
            lock.unlock()
            return
        }
        lock.unlock()
        do {
            try handle.write(contentsOf: data)
        } catch {
            dataTask.cancel()
            finish(for: dataTask, .failure(error))
            return
        }
        lock.lock()
        guard isCurrentLocked(task: dataTask) else {
            lock.unlock()
            return
        }
        writtenThisChunk += Int64(data.count)
        let callback = onBytes
        lock.unlock()
        callback?(Int64(data.count))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard isCurrent(task: task) else { return }
        let result: Result<Void, Error>
        if let error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                result = .failure(CancellationError())
            } else {
                result = .failure(error)
            }
        } else if writtenBytes() != expectedBytes() {
            // SHORT-READ GUARD: a clean completion that didn't deliver the full closed range must NOT
            // be treated as success — otherwise the caller would mark a partial chunk complete and the
            // final file would have a hole. -2 distinguishes it from an HTTP status.
            result = .failure(HFDownloader.Failure.http(-2))
        } else {
            result = .success(())
        }
        finish(for: task, result)
    }

    /// Resume the current fetch's continuation exactly once.
    private func finish(for task: URLSessionTask, _ result: Result<Void, Error>) {
        lock.lock()
        guard isCurrentLocked(task: task), let c = cont else {
            lock.unlock()
            return
        }
        cont = nil
        lock.unlock()
        c.resume(with: result)
    }

    private func isCurrent(task: URLSessionTask) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCurrentLocked(task: task)
    }

    private func isCurrentLocked(task: URLSessionTask) -> Bool {
        activeTaskIdentifier == task.taskIdentifier
    }

    private func currentRange(for task: URLSessionTask) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard isCurrentLocked(task: task) else { return nil }
        return currentRange
    }

    private func writtenBytes() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return writtenThisChunk
    }

    private func expectedBytes() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return expectedLength
    }

    /// Total file size from a 206's `Content-Range: bytes a-b/total`, else `Content-Length` plus the
    /// request offset (a 200 full response), else -1. A tiny private copy — deliberately not coupled
    /// to `HFDownloader`'s private parser.
    private static func parseTotal(_ http: HTTPURLResponse, fallbackOffset: Int64) -> Int64 {
        if let cr = http.value(forHTTPHeaderField: "Content-Range"),
            let slash = cr.lastIndex(of: "/"),
            let t = Int64(cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespaces))
        {
            return t
        }
        if let len = http.value(forHTTPHeaderField: "Content-Length"), let l = Int64(len) {
            return fallbackOffset + l
        }
        return -1
    }
}
