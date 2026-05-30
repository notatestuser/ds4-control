import XCTest

@testable import DS4Control

final class ChatSSEParserTests: XCTestCase {
    func testParsesContentDelta() {
        let line = #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#
        XCTAssertEqual(ChatSSEParser.parse(line: line), .delta("Hello"))
    }

    func testParsesDoneTerminator() {
        XCTAssertEqual(ChatSSEParser.parse(line: "data: [DONE]"), .done)
    }

    func testDoneWithoutSpace() {
        XCTAssertEqual(ChatSSEParser.parse(line: "data:[DONE]"), .done)
    }

    func testBlankLineIgnored() {
        XCTAssertEqual(ChatSSEParser.parse(line: ""), .ignored)
    }

    func testNonDataLineIgnored() {
        XCTAssertEqual(ChatSSEParser.parse(line: ": keep-alive comment"), .ignored)
    }

    func testMalformedJSONIgnored() {
        XCTAssertEqual(ChatSSEParser.parse(line: "data: {not json"), .ignored)
    }

    func testEmptyDeltaContentIgnored() {
        let line = #"data: {"choices":[{"delta":{"content":""}}]}"#
        XCTAssertEqual(ChatSSEParser.parse(line: line), .ignored)
    }

    func testMissingContentKeyIgnored() {
        let line = #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#
        XCTAssertEqual(ChatSSEParser.parse(line: line), .ignored)
    }

    func testEmptyChoicesIgnored() {
        XCTAssertEqual(ChatSSEParser.parse(line: #"data: {"choices":[]}"#), .ignored)
    }

    func testMultilineContentPreserved() {
        let line = #"data: {"choices":[{"delta":{"content":"line1\nline2"}}]}"#
        XCTAssertEqual(ChatSSEParser.parse(line: line), .delta("line1\nline2"))
    }

    func testLeadingWhitespaceTolerated() {
        let line = #"  data: {"choices":[{"delta":{"content":"x"}}]}"#
        XCTAssertEqual(ChatSSEParser.parse(line: line), .delta("x"))
    }

    func testUnicodeContent() {
        let line = #"data: {"choices":[{"delta":{"content":"héllo ✓"}}]}"#
        XCTAssertEqual(ChatSSEParser.parse(line: line), .delta("héllo ✓"))
    }
}
