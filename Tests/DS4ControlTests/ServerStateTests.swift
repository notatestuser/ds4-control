import XCTest
@testable import DS4Control

final class ServerStateTests: XCTestCase {
    func testEquatable() {
        XCTAssertEqual(ServerState.ready, .ready)
        XCTAssertNotEqual(ServerState.ready, .idle)
        XCTAssertEqual(ServerState.error(.crashed(tail: "x")), .error(.crashed(tail: "x")))
    }
    func testVerificationClamp() {
        for (input, expected) in [(-5.0, 0.0), (150, 100), (0, 0), (100, 100), (42.5, 42.5)] {
            let progress = VerificationProgress(
                label: "Verifying…", pct: input, processedBytes: 12, totalBytes: 24)
            XCTAssertEqual(progress.pct, expected)
            XCTAssertEqual(progress.label, "Verifying…")
            XCTAssertEqual(progress.processedBytes, 12)
            XCTAssertEqual(progress.totalBytes, 24)
        }
    }
    func testDownloadClamp() {
        XCTAssertEqual(DownloadProgress(pct: 150, file: "f", receivedBytes: 1, totalBytes: nil).pct, 100)
        XCTAssertEqual(DownloadProgress(pct: -5, file: "f", receivedBytes: 1, totalBytes: nil).pct, 0)
    }
    /// Only loading/serving states lock the popup's model picker; during `.stopping` the
    /// selection can change for the next Start, and idle/error/downloading don't run a server.
    func testIsServerActiveCoversLoadingAndServingOnly() {
        XCTAssertTrue(ServerState.starting.isServerActive)
        XCTAssertTrue(ServerState.ready.isServerActive)
        XCTAssertFalse(ServerState.idle.isServerActive)
        XCTAssertFalse(ServerState.downloading.isServerActive)
        XCTAssertFalse(ServerState.stopping.isServerActive)
        XCTAssertFalse(ServerState.error(.unhealthy).isServerActive)
    }
}
