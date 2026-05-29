import XCTest

@testable import DS4Control

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
