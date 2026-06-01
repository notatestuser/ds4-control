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

    func testHeadingTextPreserved() {
        let result = MarkdownText.attributedString(for: "## Hello there")
        XCTAssertEqual(result.string, "Hello there")
    }

    func testHeadingGoldenScale() {
        let body = Double(NSFont.systemFontSize)
        func headingPointSize(_ markdown: String) -> CGFloat {
            let s = MarkdownText.attributedString(for: markdown)
            return (s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        }
        let h1 = headingPointSize("# Title")
        let h2 = headingPointSize("## Title")
        let h3 = headingPointSize("### Title")
        XCTAssertEqual(h1, CGFloat((body * 1.618).rounded()))  // H1 = body·φ
        XCTAssertGreaterThan(h1, h2)  // strictly descending scale
        XCTAssertGreaterThan(h2, h3)
        XCTAssertGreaterThan(h3, CGFloat(body))  // H1–H3 exceed body
    }

    func testDeepHeadingsParsed() {
        // #### through ###### must parse as headings (markers stripped).
        XCTAssertEqual(MarkdownText.attributedString(for: "#### Four").string, "Four")
        XCTAssertEqual(MarkdownText.attributedString(for: "##### Five").string, "Five")
        XCTAssertEqual(MarkdownText.attributedString(for: "###### Six").string, "Six")

        let body = CGFloat(NSFont.systemFontSize)
        func size(_ markdown: String) -> CGFloat {
            (MarkdownText.attributedString(for: markdown).attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?
                .pointSize ?? 0
        }
        XCTAssertEqual(size("#### H4"), body)  // H4 = body·φ^0
        XCTAssertGreaterThan(size("### H3"), size("#### H4"))  // scale keeps descending
        XCTAssertGreaterThan(size("#### H4"), size("##### H5"))
    }

    func testSevenHashesIsNotHeading() {
        // CommonMark: 7+ leading #'s is a paragraph, not a heading — markers stay literal.
        let result = MarkdownText.attributedString(for: "####### Seven")
        XCTAssertTrue(result.string.contains("#######"))
    }

    /// Guards the AppKit↔SwiftUI layout feedback loop: once height is stable, `layout()`
    /// must stop invalidating the intrinsic size, or the enclosing NSHostingView spins
    /// the main thread at 100% CPU (the "freezes on second message" bug).
    func testIntrinsicTextViewLayoutSettles() {
        final class CountingTextView: IntrinsicTextView {
            var invalidations = 0
            override func invalidateIntrinsicContentSize() {
                invalidations += 1
                super.invalidateIntrinsicContentSize()
            }
        }
        let tv = CountingTextView()
        tv.frame = NSRect(x: 0, y: 0, width: 300, height: 0)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.textStorage?.setAttributedString(NSAttributedString(string: "line one\nline two\nline three"))

        tv.layout()
        tv.layout()
        let settled = tv.invalidations
        tv.layout()  // identical content + width → must not invalidate again
        tv.layout()
        XCTAssertEqual(
            tv.invalidations, settled,
            "layout() must not re-invalidate intrinsic size when the height is unchanged")
    }
}
