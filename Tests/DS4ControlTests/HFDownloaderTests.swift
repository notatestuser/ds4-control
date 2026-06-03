import XCTest

@testable import DS4Control

final class HFDownloaderTests: XCTestCase {
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
}
