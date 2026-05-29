import XCTest
@testable import DS4Control

final class ServerStateTests: XCTestCase {
    func testEquatable() {
        XCTAssertEqual(ServerState.ready, .ready)
        XCTAssertNotEqual(ServerState.ready, .idle)
        XCTAssertEqual(ServerState.error(.crashed(tail: "x")), .error(.crashed(tail: "x")))
    }
    func testDownloadClamp() {
        XCTAssertEqual(DownloadProgress(pct: 150, file: "f", receivedBytes: 1, totalBytes: nil).pct, 100)
        XCTAssertEqual(DownloadProgress(pct: -5, file: "f", receivedBytes: 1, totalBytes: nil).pct, 0)
    }
}
