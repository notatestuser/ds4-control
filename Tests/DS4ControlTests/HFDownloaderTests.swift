import XCTest

@testable import DS4Control

final class HFDownloaderTests: XCTestCase {
    override func tearDown() {
        DownloaderMockURLProtocol.reset()
        super.tearDown()
    }

    func testDefaultWorkerCountIsCGNATSafe() {
        XCTAssertEqual(HFDownloader.workerCount(highPerformance: false), 14)
        XCTAssertEqual(HFDownloader.workerCount(highPerformance: true), 64)
    }

    func testDownloadReplacesInvalidExistingFinalFile() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let file = "unit.gguf"
        try Data("BAD!".utf8).write(to: dir.appendingPathComponent(file))
        let body = Data("GGUF1234".utf8)
        let ranges = RequestedRanges()
        DownloaderMockURLProtocol.setHandler { request, proto in
            let range = request.value(forHTTPHeaderField: "Range") ?? ""
            ranges.append(range)
            let parsed = Self.parseRange(range)
            let chunk = body.subdata(in: parsed.start..<(parsed.end + 1))
            proto.respond(
                status: 206,
                headers: [
                    "Content-Range": "bytes \(parsed.start)-\(parsed.end)/\(body.count)",
                    "Content-Length": "\(chunk.count)",
                ],
                body: chunk)
        }

        let downloader = HFDownloader(
            repo: "unit/repo", endpoint: "https://unit.test", maxRetries: 0,
            protocolClasses: [DownloaderMockURLProtocol.self])
        try await downloader.download(file: file, into: dir, token: nil, highPerformance: false, chunkSize: 4) {
            _, _ in
        }

        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(file)), body)
        XCTAssertTrue(ranges.values.contains("bytes=0-0"), "must probe the remote total before trusting an existing file")
        XCTAssertTrue(ranges.values.contains("bytes=0-3"))
        XCTAssertTrue(ranges.values.contains("bytes=4-7"))
    }

    private static func parseRange(_ range: String) -> (start: Int, end: Int) {
        let trimmed = range.replacingOccurrences(of: "bytes=", with: "")
        let pieces = trimmed.split(separator: "-", maxSplits: 1).compactMap { Int($0) }
        precondition(pieces.count == 2, "unexpected range: \(range)")
        return (pieces[0], pieces[1])
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
        try await downloader.download(file: file, into: dir, token: nil, highPerformance: false) { received, total in
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
        ) { received, total in
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
            ) { _, _ in }
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
        ) { received, total in
            progress.set(received, total)
        }
        try assertCompleteGGUF(dir.appendingPathComponent(file), expectedTotal: progress.total)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "sidecar dropped on completion")
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path), ".part renamed away on completion")
    }

    /// Opt-in full DS4 download check. This writes the real V4 Flash q2-imatrix GGUF to the app's local
    /// model directory and intentionally is not part of normal test runs.
    func testDownloadsDeepSeekV4FlashQ2ImatrixLocally() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DS4_DEEPSEEK_FLASH_Q2_DOWNLOAD_TEST"] == "1",
            "large DS4 download test — set DS4_DEEPSEEK_FLASH_Q2_DOWNLOAD_TEST=1 to run")

        try await downloadDeepSeekV4FlashLocally(
            file: Quant.q2Imatrix.ggufFilename,
            quant: .q2Imatrix,
            label: "DeepSeek V4 Flash q2-imatrix")
    }

    /// Opt-in full DS4 download check for the smallest Flash file not usually covered by local setup.
    func testDownloadsDeepSeekV4FlashQ2Q4ImatrixLocally() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DS4_DEEPSEEK_FLASH_Q2Q4_DOWNLOAD_TEST"] == "1",
            "large DS4 download test — set DS4_DEEPSEEK_FLASH_Q2Q4_DOWNLOAD_TEST=1 to run")

        try await downloadDeepSeekV4FlashLocally(
            file: Quant.q2q4Imatrix.ggufFilename,
            quant: .q2q4Imatrix,
            label: "DeepSeek V4 Flash q2-q4-imatrix")
    }

    private func downloadDeepSeekV4FlashLocally(file: String, quant: Quant, label: String) async throws {
        let dir =
            ProcessInfo.processInfo.environment["DS4_GGUF_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? ds4AppSupportDir().appendingPathComponent("gguf", isDirectory: true)
        let progress = LargeDownloadProgress(label: label)
        let token = resolveHFToken(
            env: ProcessInfo.processInfo.environment,
            cacheFile: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/huggingface/token"))

        try await HFDownloader(repo: "antirez/deepseek-v4-gguf").download(
            file: file, into: dir, token: token, highPerformance: false
        ) { received, total in
            progress.report(received: received, total: total)
        }

        let out = dir.appendingPathComponent(file)
        XCTAssertTrue(
            ModelFileValidator.isValidGGUF(
                at: out, minimumBytes: ModelFileValidator.minimumBytes(for: quant)))
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)
        XCTAssertGreaterThanOrEqual(size.int64Value, ModelFileValidator.minimumBytes(for: quant))
    }
}

private final class LargeDownloadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let label: String
    private var lastReportedGiB: Int64 = -1

    init(label: String) {
        self.label = label
    }

    func report(received: Int64, total: Int64) {
        let receivedGiB = received / 1_073_741_824
        lock.lock()
        guard receivedGiB != lastReportedGiB else {
            lock.unlock()
            return
        }
        lastReportedGiB = receivedGiB
        lock.unlock()

        let totalText = total > 0 ? String(format: "%.1f", Double(total) / 1_073_741_824) : "?"
        let line = "\(label): \(receivedGiB) GiB / \(totalText) GiB\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

private final class RequestedRanges: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ value: String) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }
}

private final class DownloaderMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, DownloaderMockURLProtocol) -> Void

    private static let lock = NSLock()
    nonisolated(unsafe)
    private static var handler: Handler?

    static func setHandler(_ newHandler: @escaping Handler) {
        lock.lock()
        handler = newHandler
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "unit.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let h = Self.handler
        Self.lock.unlock()
        guard let h else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        h(request, self)
    }

    override func stopLoading() {}

    func respond(status: Int, headers: [String: String], body: Data) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
}
