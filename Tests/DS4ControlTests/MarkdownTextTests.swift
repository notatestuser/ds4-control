import XCTest

@testable import DS4Control

@MainActor
final class MarkdownTextTests: XCTestCase {
    // deLaTeXed (unchanged behavior; renderer-agnostic)
    func testDeLaTeXBoxedAnswerBecomesBold() {
        let out = MarkdownText.deLaTeXed("All seven.\n\\[\n\\boxed{7}\n\\]")
        XCTAssertTrue(out.contains("**7**"))
        XCTAssertFalse(out.contains("\\boxed"))
        XCTAssertFalse(out.contains("\\["))
        XCTAssertFalse(out.contains("\\]"))
    }

    func testDeLaTeXStripsDelimitersAndMapsMacros() {
        XCTAssertEqual(MarkdownText.deLaTeXed("\\(x+1\\)"), "x+1")
        XCTAssertFalse(MarkdownText.deLaTeXed("$$a$$").contains("$"))
        XCTAssertEqual(MarkdownText.deLaTeXed("3 \\times 4"), "3 × 4")
        XCTAssertEqual(MarkdownText.deLaTeXed("\\frac{1}{2}"), "1/2")
        XCTAssertEqual(MarkdownText.deLaTeXed("\\text{hello}"), "hello")
    }

    func testDeLaTeXLongerMacroNotEatenByShorter() {
        XCTAssertEqual(MarkdownText.deLaTeXed("a \\cdots b"), "a ⋯ b")
        XCTAssertEqual(MarkdownText.deLaTeXed("a \\cdot b"), "a · b")
        XCTAssertEqual(MarkdownText.deLaTeXed("x \\leq y"), "x ≤ y")
        XCTAssertEqual(MarkdownText.deLaTeXed("\\unknown"), "\\unknown")
    }

    // preprocess tag stripping (replaces the old hidden-tag attributedString test)
    func testPreprocessStripsToolCallBlock() {
        let out = MarkdownText.preprocess("<tool_call>\nsecret\n</tool_call>")
        XCTAssertFalse(out.contains("secret"))
    }

    func testPreprocessStripsThinkingBlockButKeepsAnswer() {
        let out = MarkdownText.preprocess("<thinking>\nhidden reasoning\n</thinking>\nThe answer is 42.")
        XCTAssertFalse(out.contains("hidden reasoning"))
        XCTAssertTrue(out.contains("The answer is 42."))
    }

    func testPreprocessStripsInlineThinkingLine() {
        XCTAssertEqual(MarkdownText.preprocess("Before\n<think>x</think>\nAfter"), "Before\nAfter")
    }

    func testPreprocessKeepsOrdinaryMarkdown() {
        let out = MarkdownText.preprocess("## Heading\n\n- item")
        XCTAssertTrue(out.contains("## Heading"))
        XCTAssertTrue(out.contains("- item"))
    }
}
