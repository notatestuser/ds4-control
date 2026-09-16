import XCTest

@testable import DS4Control

final class HFDownloaderTests: XCTestCase {
    func testWorkerCountTiers() {
        XCTAssertEqual(HFDownloader.workerCount(highPerformance: false), 8)  // CGNAT-safe default
        XCTAssertEqual(HFDownloader.workerCount(highPerformance: true), 64)  // opt-in aggressive cap
    }

    /// The ramp's decision logic: baseline-then-double while windows improve by ≥10%, revert to
    /// the best count and stop on the first window that fails to improve (the 64-connection
    /// freeze seen over lossy paths), re-measure before settling at the cap, and treat stalled
    /// windows as failures.
    func testWorkerRampPolicy() {
        var ramp = WorkerRamp(start: 8, cap: 64)
        XCTAssertTrue(ramp.allows(7))
        XCTAssertFalse(ramp.allows(8))

        XCTAssertEqual(ramp.observe(rate: 100), 16, "the baseline window then tries more")  // 8 → 16
        XCTAssertEqual(ramp.observe(rate: 150), 32, "a ≥10% improvement doubles toward the cap")
        XCTAssertEqual(ramp.observe(rate: 200), 64, "still improving → the cap")
        XCTAssertFalse(ramp.finished, "the cap is still measured before settling")
        XCTAssertTrue(ramp.allows(63))
        XCTAssertEqual(ramp.observe(rate: 260), 64, "an improving window at the cap holds it")
        XCTAssertTrue(ramp.finished)

        var capDrop = WorkerRamp(start: 8, cap: 64)
        XCTAssertEqual(capDrop.observe(rate: 100), 16)
        XCTAssertEqual(capDrop.observe(rate: 150), 32)
        XCTAssertEqual(capDrop.observe(rate: 200), 64)
        XCTAssertEqual(capDrop.observe(rate: 100), 32, "a drop at the cap settles back at the best")
        XCTAssertTrue(capDrop.finished)

        var degrading = WorkerRamp(start: 8, cap: 64)
        XCTAssertEqual(degrading.observe(rate: 100), 16)  // baseline → try 16
        XCTAssertEqual(degrading.observe(rate: 60), 8, "first non-improvement reverts to the best")
        XCTAssertTrue(degrading.finished)
        XCTAssertFalse(degrading.allows(8), "extra workers are told to stop")

        var flat = WorkerRamp(start: 8, cap: 64)
        XCTAssertEqual(flat.observe(rate: 100), 16)
        XCTAssertEqual(flat.observe(rate: 105), 8, "+5% is within noise, not an improvement")
        XCTAssertTrue(flat.finished)

        var stalled = WorkerRamp(start: 8, cap: 64)
        XCTAssertEqual(stalled.observe(rate: 0), 8, "a stalled window before the baseline adds nothing")
        XCTAssertEqual(stalled.observe(rate: 100), 16)
        XCTAssertEqual(stalled.observe(rate: 0), 8, "a stall after ramp-up reverts and stops")
        XCTAssertTrue(stalled.finished)
    }

    /// The measurement window is quantization-aware: long enough for ~2 chunks at the current
    /// rate, floored and capped so tiny or huge rates can't produce noisy or glacial windows.
    func testRampWindowSeconds() {
        let chunk: Int64 = 256 * 1024 * 1024
        XCTAssertEqual(HFDownloader.rampWindowSeconds(rate: 0, chunkSize: chunk), 8)
        XCTAssertEqual(HFDownloader.rampWindowSeconds(rate: 8_000_000, chunkSize: chunk), 30)  // slow → capped
        XCTAssertEqual(HFDownloader.rampWindowSeconds(rate: 2_000_000_000, chunkSize: chunk), 8)  // fast → floored
        let twoChunks = 2 * Double(chunk)  // exactly the ~2-chunk window
        XCTAssertEqual(HFDownloader.rampWindowSeconds(rate: twoChunks, chunkSize: chunk), 8, accuracy: 0.01)
        let smallFile = HFDownloader.rampWindowSeconds(
            rate: 10_000_000, chunkSize: 65_536, minWindow: 0.05)
        XCTAssertEqual(smallFile, 0.05, accuracy: 0.001, "small-file tests can lower the floor")
    }

    /// Real end-to-end network download of a small public GGUF through the native `HFDownloader`:
    /// `/resolve` → cas-bridge/LFS redirect → closed-range chunk(s) → completion → rename, then
    /// verifies the size matches the server's total and the bytes are a valid GGUF.
    ///
    /// Opt-in (set `DS4_NETWORK_TESTS=1`) so CI doesn't pull ~320 MB on every run.
    func testDownloadsSmallGGUF() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DS4_NETWORK_TESTS"] == "1",
            "network test — set DS4_NETWORK_TESTS=1 to run")

        let repo = "AtomicChat/gemma-4-26B-A4B-it-assistant-GGUF"
        let file = "gemma-4-26B-A4B-it-assistant.Q4_K_S.gguf"  // ~321 MB, public, single chunk
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }

        final class Progress: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var received: Int64 = 0
            private(set) var total: Int64 = -1
            func set(_ r: Int64, _ t: Int64) {
                lock.withLock {
                    received = r; total = t
                }
            }
        }
        let progress = Progress()
        let downloader = HFDownloader(repo: repo)
        try await downloader.download(file: file, into: dir, token: nil, highPerformance: false) { received, total, _ in
            progress.set(received, total)
        }

        let out = dir.appendingPathComponent(file)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int)
        XCTAssertGreaterThan(size, 300_000_000, "expected the ~321 MB GGUF on disk")
        if progress.total > 0 {
            XCTAssertEqual(Int64(size), progress.total, "downloaded size must equal the server-reported total")
        }
        XCTAssertGreaterThan(progress.received, 0, "progress callback must have fired")

        let handle = try FileHandle(forReadingFrom: out)
        defer { try? handle.close() }
        XCTAssertEqual(handle.readData(ofLength: 4), Data("GGUF".utf8), "must be a valid GGUF (magic header)")
    }

    /// Lock-protected box so the `@Sendable` onProgress closure can record the latest (received, total)
    /// across worker threads without data races (mirrors the `Progress` box in the test above).
    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var received: Int64 = 0
        private(set) var total: Int64 = -1
        func set(_ r: Int64, _ t: Int64) {
            lock.withLock {
                received = r
                total = t
            }
        }
    }

    /// Lock-protected recorder for the progress callback's connection counts.
    private final class ConnsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func add(_ n: Int) {
            lock.withLock { values.append(n) }
        }
        var all: [Int] {
            lock.withLock { values }
        }
    }

    /// Public gemma repo + ~321 MB GGUF, downloaded with a deliberately SMALL chunk size so the file
    /// splits into ~20 chunks — exercising the real PARALLEL path (workers, offset writes, bitmap)
    /// end-to-end, not the trivial single-chunk path.
    private static let gemmaRepo = "AtomicChat/gemma-4-26B-A4B-it-assistant-GGUF"
    private static let gemmaFile = "gemma-4-26B-A4B-it-assistant.Q4_K_S.gguf"
    private static let smallChunk: Int64 = 16 * 1024 * 1024  // ~20 chunks across ~321 MB

    /// Assert `out` is the fully-downloaded gemma GGUF: size == server `total`, starts with "GGUF".
    private func assertCompleteGGUF(_ out: URL, expectedTotal: Int64) throws {
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int)
        XCTAssertGreaterThan(size, 300_000_000, "expected the ~321 MB GGUF on disk")
        XCTAssertEqual(Int64(size), expectedTotal, "downloaded size must equal the server-reported total")
        let handle = try FileHandle(forReadingFrom: out)
        defer { try? handle.close() }
        XCTAssertEqual(handle.readData(ofLength: 4), Data("GGUF".utf8), "must be a valid GGUF (magic header)")
    }

    /// PARALLEL download (highPerformance:true) with the small injected chunk size → ~20 chunks fetched
    /// concurrently to their offsets in `<file>.part`, then renamed to the final file. Asserts the
    /// final file is byte-correct (size == server total, GGUF magic) and progress fired.
    func testParallelDownloadSmallChunks() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DS4_NETWORK_TESTS"] == "1",
            "network test — set DS4_NETWORK_TESTS=1 to run")

        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }

        let progress = ProgressBox()
        let downloader = HFDownloader(repo: Self.gemmaRepo)
        try await downloader.download(
            file: Self.gemmaFile, into: dir, token: nil, highPerformance: true, chunkSize: Self.smallChunk
        ) { received, total, _ in
            progress.set(received, total)
        }

        XCTAssertGreaterThan(progress.total, 0, "the server total must have been resolved")
        XCTAssertGreaterThan(progress.received, 0, "progress callback must have fired")
        try assertCompleteGGUF(dir.appendingPathComponent(Self.gemmaFile), expectedTotal: progress.total)
        // The `.part` and its sidecar must be gone once the file is finalised + renamed.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(Self.gemmaFile + ".part").path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(Self.gemmaFile + ".part.dl").path))
    }

    /// RESUME via the bitmap: start a parallel download, cancel it once ≥2 chunks are durably complete
    /// (sidecar bits set), assert the `.part` + `.part.dl` survive the cancel with chunks marked, then
    /// run `download` again to completion and assert the final file is byte-correct. Proves bitmap
    /// resume + sparse-offset overwrite: the second run only fetches the chunks the first one lacked.
    func testParallelDownloadResumesFromBitmap() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DS4_NETWORK_TESTS"] == "1",
            "network test — set DS4_NETWORK_TESTS=1 to run")

        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let repo = Self.gemmaRepo
        let file = Self.gemmaFile
        let chunk = Self.smallChunk
        let sidecar = dir.appendingPathComponent(file + ".part.dl")
        let part = dir.appendingPathComponent(file + ".part")

        // First pass: start downloading, let it run until the sidecar records ≥2 completed chunks, then
        // cancel the Task. (Default highPerformance:false keeps the worker count modest for the wait.)
        let task = Task {
            let downloader = HFDownloader(repo: repo)
            try await downloader.download(
                file: file, into: dir, token: nil, highPerformance: false, chunkSize: chunk
            ) { _, _, _ in }
        }
        // Poll the sidecar's durable bytes until ≥2 chunks are complete (or the whole thing finishes).
        var resumedBytes: Int64 = 0
        for _ in 0..<600 {  // up to ~60 s
            resumedBytes = resumableBytes(ggufDir: dir, filename: file)
            if resumedBytes >= 2 * chunk { break }
            // If the file already finalised (small/fast), there's nothing to resume — bail to a fresh dir.
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        task.cancel()
        _ = try? await task.value  // drain the cancellation

        // The partial + sidecar must survive the cancel with ≥2 chunks marked complete.
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path), "sparse .part must persist across cancel")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path), "bitmap sidecar must persist")
        XCTAssertGreaterThanOrEqual(
            resumableBytes(ggufDir: dir, filename: file), 2 * chunk,
            "≥2 chunks must be durably recorded before resume")

        // Second pass: resume to completion in the SAME dir → only the missing chunks are fetched.
        let progress = ProgressBox()
        let downloader = HFDownloader(repo: repo)
        try await downloader.download(
            file: file, into: dir, token: nil, highPerformance: false, chunkSize: chunk
        ) { received, total, _ in
            progress.set(received, total)
        }
        try assertCompleteGGUF(dir.appendingPathComponent(file), expectedTotal: progress.total)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "sidecar dropped on completion")
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path), ".part renamed away on completion")
    }

    /// A first-contact network blip must not freeze the download (spinner, 0%, no speed): the probe
    /// retries transient failures, then the chunk fetch proceeds normally.
    func testProbeRetriesTransientFailureThenCompletes() async throws {
        MockHFProtocol.state.reset(failFirst: true, alwaysFail: false)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockHFProtocol.self]
        let dl = HFDownloader(repo: "test/repo", sessionConfiguration: cfg, probeRetryBackoff: 0.01)

        try await dl.download(file: "tiny.gguf", into: dir, token: nil, highPerformance: false) { _, _, _ in }

        XCTAssertEqual(
            try Data(contentsOf: dir.appendingPathComponent("tiny.gguf")), MockHFProtocol.state.body)
        XCTAssertEqual(
            MockHFProtocol.state.requestCount, 3,
            "one failed probe + the retried probe + one chunk fetch")
    }

    /// A persistently failing server must surface as a bounded error (banner + Retry), never as an
    /// eternal spinner: the probe's attempts are capped.
    func testProbeExhaustionFailsInsteadOfHanging() async throws {
        MockHFProtocol.state.reset(failFirst: false, alwaysFail: true)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockHFProtocol.self]
        let dl = HFDownloader(repo: "test/repo", sessionConfiguration: cfg, probeRetryBackoff: 0.01)

        do {
            try await dl.download(file: "tiny.gguf", into: dir, token: nil, highPerformance: false) { _, _, _ in }
            XCTFail("an all-503 server must fail the download")
        } catch let e as HFDownloader.Failure {
            XCTAssertEqual(e, .http(503))
        }
        XCTAssertEqual(
            MockHFProtocol.state.requestCount, 3, "probe attempts must be bounded, not unlimited")
    }

    /// A persist-per-chunk delay of `base × active²` makes aggregate throughput FALL as
    /// connections multiply — the lossy-tunnel regime where 64 workers froze a real download at
    /// ~0 MB/s. The ramp must back off instead of racing to the cap, and no chunk may be lost
    /// when extra workers are told to stop.
    func testHighPerformanceRampBacksOffWhenMoreConnectionsHurt() async throws {
        MockHFProtocol.state.reset(failFirst: false, alwaysFail: false)
        let total = 64 * 65_536
        MockHFProtocol.state.configure(total: Int64(total), body: Data(repeating: 0, count: total))
        MockHFProtocol.state.setDelayBase(0.002)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockHFProtocol.self]
        let dl = HFDownloader(repo: "test/repo", sessionConfiguration: cfg, minRampWindow: 0.05)
        let conns = ConnsBox()

        try await dl.download(
            file: "ramped.gguf", into: dir, token: nil, highPerformance: true, chunkSize: 65_536
        ) { _, _, connections in
            conns.add(connections)
        }

        XCTAssertEqual(
            try Data(contentsOf: dir.appendingPathComponent("ramped.gguf")).count, total,
            "workers exiting mid-ramp must not lose any chunk")
        XCTAssertGreaterThanOrEqual(
            MockHFProtocol.state.maxActive, 8, "the ramp must start with the base workers")
        XCTAssertLessThan(
            MockHFProtocol.state.maxActive, 64,
            "a degrading path must stop growing instead of racing to the cap")
        XCTAssertEqual(conns.all.first, 8, "the baseline reports the base pool")
        let promoted = try XCTUnwrap(
            conns.all.firstIndex(of: 16), "a promotion must be reported to the UI")
        XCTAssertTrue(
            conns.all[promoted...].contains(8),
            "the backed-off pool must be reported after the first non-improving window")
    }

    /// Without High Performance the pool is fixed: every reported count is the base.
    func testProgressReportsBaseConnectionsWithoutHighPerformance() async throws {
        MockHFProtocol.state.reset(failFirst: false, alwaysFail: false)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockHFProtocol.self]
        let dl = HFDownloader(repo: "test/repo", sessionConfiguration: cfg)
        let conns = ConnsBox()

        try await dl.download(file: "plain.gguf", into: dir, token: nil, highPerformance: false) {
            _, _, connections in
            conns.add(connections)
        }

        XCTAssertEqual(Set(conns.all), [8], "a fixed pool always reports the base count")
    }

    /// The session must fail fast instead of parking in `.waitingForConnectivity`: that wait is
    /// unbounded for the probe (no progress callbacks → spinner with no speed) and for the workers
    /// (their per-chunk backoff is the designed transient-recovery path).
    func testDownloadSessionFailsFastInsteadOfWaitingForConnectivity() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/DS4Control/Services/HFDownloader.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("waitsForConnectivity = false"))
    }

    /// The injected configuration is a borrowed reference: the download must copy it before
    /// applying its session settings, never mutate the shared instance under another download.
    func testInjectedSessionConfigurationIsNotMutated() async throws {
        MockHFProtocol.state.reset(failFirst: false, alwaysFail: false)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockHFProtocol.self]
        cfg.httpMaximumConnectionsPerHost = 13  // sentinel the download would overwrite to 8
        let dl = HFDownloader(repo: "test/repo", sessionConfiguration: cfg, probeRetryBackoff: 0.01)

        try await dl.download(file: "tiny.gguf", into: dir, token: nil, highPerformance: false) { _, _, _ in }

        XCTAssertEqual(
            cfg.httpMaximumConnectionsPerHost, 13,
            "the injected configuration must not be mutated by a download")
    }

    /// The test-facing backoff knob must be sanitized before the `UInt64` nanosecond conversion:
    /// a negative or non-finite value would otherwise trap and crash the app.
    func testUnsafeProbeBackoffValuesDoNotTrap() async throws {
        for badBackoff in [-5.0, Double.nan] {
            MockHFProtocol.state.reset(failFirst: true, alwaysFail: false)
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let cfg = URLSessionConfiguration.ephemeral
            cfg.protocolClasses = [MockHFProtocol.self]
            let dl = HFDownloader(
                repo: "test/repo", sessionConfiguration: cfg, probeRetryBackoff: badBackoff)

            try await dl.download(file: "tiny.gguf", into: dir, token: nil, highPerformance: false) { _, _, _ in }

            XCTAssertEqual(
                try Data(contentsOf: dir.appendingPathComponent("tiny.gguf")), MockHFProtocol.state.body,
                "backoff \(badBackoff) must be sanitized, not trap")
        }
    }
}

/// Offline `URLProtocol` answering HF-style closed-Range requests for a configurable file.
/// Configured statically (reset per test) to fail the first request or every request, and to
/// simulate per-connection scarcity (`delayBase × active²`) so a test can degrade throughput as
/// concurrency grows — the regime the worker ramp must detect.
final class MockHFProtocol: URLProtocol {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var failFirst = false
        private var alwaysFail = false
        private var count = 0
        private var active = 0
        private var maxSeen = 0
        private var delayBase: TimeInterval = 0
        private var fileTotal: Int64 = 4
        private var fileBody = Data("GGUF".utf8)

        func reset(failFirst: Bool, alwaysFail: Bool) {
            lock.lock()
            defer { lock.unlock() }
            self.failFirst = failFirst
            self.alwaysFail = alwaysFail
            count = 0
            active = 0
            maxSeen = 0
            delayBase = 0
            fileTotal = 4
            fileBody = Data("GGUF".utf8)
        }

        func configure(total: Int64, body: Data) {
            lock.lock()
            defer { lock.unlock() }
            fileTotal = total
            fileBody = body
        }

        func setDelayBase(_ seconds: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            delayBase = seconds
        }

        /// Record a request beginning: whether it should fail, and the live concurrency.
        func enter() -> (fail: Bool, active: Int) {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            active += 1
            maxSeen = max(maxSeen, active)
            return (alwaysFail || (failFirst && count == 1), active)
        }

        func leave() {
            lock.lock()
            defer { lock.unlock() }
            active -= 1
        }

        var perConnectionDelayBase: TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return delayBase
        }

        var total: Int64 {
            lock.lock()
            defer { lock.unlock() }
            return fileTotal
        }

        var body: Data {
            lock.lock()
            defer { lock.unlock() }
            return fileBody
        }

        var requestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        var maxActive: Int {
            lock.lock()
            defer { lock.unlock() }
            return maxSeen
        }
    }

    static let state = State()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private let stopLock = NSLock()
    private var stopped = false
    override func stopLoading() {
        stopLock.lock()
        stopped = true
        stopLock.unlock()
    }
    private var isStopped: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }

    override func startLoading() {
        let entry = Self.state.enter()
        if entry.fail {
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            Self.state.leave()
            return
        }
        let delay = Self.state.perConnectionDelayBase * Double(entry.active * entry.active)
        // Deliver asynchronously: sleeping the URLProtocol thread here would serialize every
        // request in the process and hide real concurrency from the ramp.
        let work = { [self] in
            defer { Self.state.leave() }
            guard !isStopped else { return }
            let total = Self.state.total
            let body = Self.state.body
            // Closed Range "bytes=a-b": the probe asks bytes=0-0, a chunk asks its slice.
            let bounds =
                (request.value(forHTTPHeaderField: "Range") ?? "bytes=0-\(total - 1)")
                .replacingOccurrences(of: "bytes=", with: "")
                .split(separator: "-")
                .compactMap { Int64($0) }
            let start = bounds.first ?? 0
            let end = bounds.count > 1 ? bounds[1] : total - 1
            let payload = body[Int(start)...Int(end)]
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Range": "bytes \(start)-\(end)/\(total)",
                    "Content-Length": "\(payload.count)",
                ])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload)
            client?.urlProtocolDidFinishLoading(self)
        }
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            work()
        }
    }
}
