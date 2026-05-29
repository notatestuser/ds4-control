import XCTest
@testable import DS4Control

final class ReadinessMatcherTests: XCTestCase {
    func testPositive() {
        XCTAssertTrue(isReadyLine("ds4-server: listening on http://127.0.0.1:8000"))
        XCTAssertTrue(isReadyLine("  LISTENING ON HTTP://0.0.0.0:9000  "))
    }
    func testNegative() {
        XCTAssertFalse(isReadyLine("ds4-server: context buffers 10.50 MiB (ctx=32768)"))
        XCTAssertFalse(isReadyLine("listening on htt"))
        XCTAssertFalse(isReadyLine(""))
    }
}
