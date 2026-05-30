import AppKit
import XCTest

@testable import DS4Control

@MainActor
final class MarkdownTextTests: XCTestCase {
    func testPlainParagraph() {
        let result = MarkdownText.attributedString(for: "Hello world")
        XCTAssertEqual(result.string, "Hello world")
    }

    func testBoldStripsMarkers() {
        let result = MarkdownText.attributedString(for: "this is **bold**")
        XCTAssertEqual(result.string, "this is bold")
    }

    func testInlineCodeStripsBackticks() {
        let result = MarkdownText.attributedString(for: "call `foo()` now")
        XCTAssertEqual(result.string, "call foo() now")
    }

    func testBulletListRendersBullets() {
        let result = MarkdownText.attributedString(for: "- one\n- two")
        XCTAssertTrue(result.string.contains("•  one"))
        XCTAssertTrue(result.string.contains("•  two"))
    }

    func testCodeBlockBodyPreserved() {
        let source = "```swift\nlet x = 1\n```"
        let result = MarkdownText.attributedString(for: source)
        XCTAssertTrue(result.string.contains("let x = 1"))
    }

    func testHiddenTagBlockOmitted() {
        let source = "<tool_call>\nsecret\n</tool_call>"
        let result = MarkdownText.attributedString(for: source)
        XCTAssertFalse(result.string.contains("secret"))
    }

    func testEmptyStringYieldsEmpty() {
        let result = MarkdownText.attributedString(for: "")
        XCTAssertEqual(result.string, "")
    }
}
