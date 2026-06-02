import XCTest

@testable import DS4Control

final class MarkdownBlocksTests: XCTestCase {
    func testEmptyInput() {
        let r = MarkdownBlocks.splitBlocks("")
        XCTAssertTrue(r.completed.isEmpty)
        XCTAssertEqual(r.tail, "")
    }

    func testNoBlankLineIsAllTail() {
        let r = MarkdownBlocks.splitBlocks("one line still streaming")
        XCTAssertTrue(r.completed.isEmpty)
        XCTAssertEqual(r.tail, "one line still streaming")
    }

    func testSplitsProseOnBlankLines() {
        let r = MarkdownBlocks.splitBlocks("First para.\n\nSecond para.\n\nThird in progress")
        XCTAssertEqual(r.completed, ["First para.", "Second para."])
        XCTAssertEqual(r.tail, "Third in progress")
    }

    func testTrailingBlankFlushesLastBlock() {
        let r = MarkdownBlocks.splitBlocks("Done para.\n\n")
        XCTAssertEqual(r.completed, ["Done para."])
        XCTAssertEqual(r.tail, "")
    }

    func testOpenFenceStaysInTail() {
        // A blank line *inside* an open fence is not a boundary; the whole open block is tail.
        let r = MarkdownBlocks.splitBlocks("Intro.\n\n```swift\nlet x = 1\n\nlet y = 2")
        XCTAssertEqual(r.completed, ["Intro."])
        XCTAssertEqual(r.tail, "```swift\nlet x = 1\n\nlet y = 2")
    }

    func testClosedFenceIsCompletedBlock() {
        let r = MarkdownBlocks.splitBlocks("```swift\nlet x = 1\n```\n\nAfter")
        XCTAssertEqual(r.completed, ["```swift\nlet x = 1\n```"])
        XCTAssertEqual(r.tail, "After")
    }
}
