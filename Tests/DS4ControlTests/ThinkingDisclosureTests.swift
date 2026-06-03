import XCTest

final class ThinkingDisclosureTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let root =
            testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testThinkingDisclosureUsesExplicitToggleButton() throws {
        let chatView = try source("Sources/DS4Control/Views/ChatView.swift")

        XCTAssertFalse(chatView.contains("DisclosureGroup(isExpanded: $expanded)"))
        XCTAssertTrue(chatView.contains("Button {"))
        XCTAssertTrue(chatView.contains("expanded.toggle()"))
        XCTAssertTrue(chatView.contains(#"Image(systemName: expanded ? "chevron.down" : "chevron.right")"#))
        XCTAssertTrue(chatView.contains("if expanded {"))
        XCTAssertTrue(chatView.contains("MarkdownText(text)"))
    }
}
