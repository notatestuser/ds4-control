import XCTest
@testable import DS4Control

final class ServerSpeedParserTests: XCTestCase {
    func testPrefillLine() {
        let s = ServerSpeedParser.feed(
            "0812 20:57:47 ds4-server: chat ctx=0..52:52 prefill chunk 52/52 (100.0%) chunk=0.00 t/s avg=67.91 t/s 0.766s"
        )
        XCTAssertEqual(s?.phase, .prefill)
        XCTAssertEqual(s?.tokensPerSecond ?? 0, 67.91, accuracy: 0.01)
        XCTAssertNil(s?.tokens)
    }
    func testDecodeLine() {
        let s = ServerSpeedParser.feed(
            "0812 20:57:47 ds4-server: chat ctx=52..57:5 gen=5 decoding chunk=41.40 t/s avg=41.40 t/s 0.121s")
        XCTAssertEqual(s?.phase, .decode)
        XCTAssertEqual(s?.tokensPerSecond ?? 0, 41.40, accuracy: 0.01)
        XCTAssertEqual(s?.tokens, 5)
    }
    func testFinishLine() {
        let s = ServerSpeedParser.feed(
            "0812 20:57:47 ds4-server: chat ctx=0..52:52 gen=5 finish=stop 0.887s")
        XCTAssertEqual(s?.phase, .idle)
        XCTAssertNil(s?.tokensPerSecond)
        XCTAssertEqual(s?.tokens, 5)
    }
    func testNonTimingLinesReturnNil() {
        XCTAssertNil(ServerSpeedParser.feed("ds4-server: listening on http://127.0.0.1:8000"))
        XCTAssertNil(ServerSpeedParser.feed("ds4: metal backend initialized for graph diagnostics"))
        // MTP batch lines are deliberately ignored: per-request lines are the clean signal.
        XCTAssertNil(ServerSpeedParser.feed("ds4-server: decode batch count=5 elapsed=12.0 ms status=ok"))
        XCTAssertNil(ServerSpeedParser.feed(""))
    }
}
