import XCTest

@testable import DS4Control

/// The rate window shared by both download tracks. `now` is injected so these don't sleep.
final class TransferRateMeterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// No reading until a full window has elapsed — otherwise the first sample would divide by a
    /// near-zero interval and print a wild number.
    func testNoReadingBeforeWindowElapses() {
        var meter = TransferRateMeter()
        XCTAssertNil(meter.sample(received: 0, now: t0))
        XCTAssertNil(meter.sample(received: 50_000_000, now: t0.addingTimeInterval(0.2)))
    }

    /// The reading is (bytes over the window) / (window), not per-callback — which is what keeps it
    /// from under-reporting when the downloader coalesces progress callbacks.
    func testReadingIsBytesOverTheWindow() {
        var meter = TransferRateMeter()
        _ = meter.sample(received: 0, now: t0)
        XCTAssertEqual(meter.sample(received: 100_000_000, now: t0.addingTimeInterval(0.5)), "200 MB/s")
    }

    /// Between window boundaries the previous reading is held, so the label doesn't blink to nil.
    func testHoldsLastReadingBetweenWindows() {
        var meter = TransferRateMeter()
        _ = meter.sample(received: 0, now: t0)
        _ = meter.sample(received: 100_000_000, now: t0.addingTimeInterval(0.5))
        XCTAssertEqual(meter.sample(received: 110_000_000, now: t0.addingTimeInterval(0.6)), "200 MB/s")
    }

    /// Reset forgets the anchor so a restarted download can't inherit a stale window.
    func testResetClearsAnchorAndReading() {
        var meter = TransferRateMeter()
        _ = meter.sample(received: 0, now: t0)
        _ = meter.sample(received: 100_000_000, now: t0.addingTimeInterval(0.5))
        meter.reset()
        XCTAssertNil(meter.sample(received: 500_000_000, now: t0.addingTimeInterval(0.6)))
    }
}

final class DownloadProbeTests: XCTestCase {
    func testFormatRate() {
        XCTAssertEqual(formatRate(213_000_000), "213 MB/s")
        XCTAssertEqual(formatRate(1_500_000_000), "1.5 GB/s")
        XCTAssertEqual(formatRate(850_000), "850 KB/s")
        XCTAssertEqual(formatRate(512), "512 B/s")
        XCTAssertEqual(formatRate(-5), "0 B/s")
    }

    func testDownloadedBytesSumsIncomplete() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let dl = dir.appendingPathComponent(".cache/huggingface/download")
        try FileManager.default.createDirectory(at: dl, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: dl.appendingPathComponent("abc123.incomplete"))
        XCTAssertEqual(downloadedBytes(ggufDir: dir, filename: "model.gguf"), 4096)
    }

    func testDownloadedBytesPrefersFinalFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 8192).write(to: dir.appendingPathComponent("model.gguf"))
        XCTAssertEqual(downloadedBytes(ggufDir: dir, filename: "model.gguf"), 8192)
    }

    func testDownloadedBytesCountsCurlPartFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // download_model.sh's curl streams to "<filename>.part" before renaming on completion.
        try Data(count: 1234).write(to: dir.appendingPathComponent("model.gguf.part"))
        XCTAssertEqual(downloadedBytes(ggufDir: dir, filename: "model.gguf"), 1234)
        // Once the final file lands it takes precedence over any leftover .part.
        try Data(count: 9999).write(to: dir.appendingPathComponent("model.gguf"))
        XCTAssertEqual(downloadedBytes(ggufDir: dir, filename: "model.gguf"), 9999)
    }

    func testDownloadedBytesZeroWhenAbsent() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(downloadedBytes(ggufDir: dir, filename: "model.gguf"), 0)
    }

    func testResolveHFTokenFromEnv() {
        XCTAssertEqual(
            resolveHFToken(env: ["HF_TOKEN": "envtok"], cacheFile: URL(fileURLWithPath: "/nope")), "envtok")
    }
    func testResolveHFTokenFromCache() throws {
        let f = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString)")
        try "cachetok\n".write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(resolveHFToken(env: [:], cacheFile: f), "cachetok")
    }
    func testResolveHFTokenEnvBeatsCache() throws {
        let f = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString)")
        try "cachetok".write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(resolveHFToken(env: ["HF_TOKEN": "envtok"], cacheFile: f), "envtok")
    }
    func testResolveHFTokenNilWhenNone() {
        XCTAssertNil(resolveHFToken(env: [:], cacheFile: URL(fileURLWithPath: "/nope/token")))
    }
}
