import XCTest

final class StreamingMarkdownStateTests: XCTestCase {
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

    func testStreamingMarkdownDoesNotPublishViewLocalTimerState() throws {
        let source = try source("Sources/DS4Control/Views/MarkdownText.swift")

        XCTAssertFalse(source.contains("@State private var shown"))
        XCTAssertFalse(source.contains("Timer.publish"))
        XCTAssertFalse(source.contains(".onReceive(Self.tick)"))
        XCTAssertTrue(source.contains("MarkdownNSText(markdown: MarkdownText.preprocess(source))"))
    }
}
