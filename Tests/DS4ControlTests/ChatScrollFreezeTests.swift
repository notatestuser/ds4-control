import XCTest

final class ChatScrollFreezeTests: XCTestCase {
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

    func testScrollFollowBookkeepingDoesNotPublishSwiftUIStateChanges() throws {
        let chatView = try source("Sources/DS4Control/Views/ChatView.swift")

        XCTAssertFalse(chatView.contains("@State private var followTask"))
        XCTAssertFalse(chatView.contains("@State private var userPinnedToBottom"))
        XCTAssertTrue(chatView.contains("private final class ScrollCoordinator"))
        XCTAssertTrue(chatView.contains("@State private var scrollCoordinator = ScrollCoordinator()"))
    }

    func testStreamingBottomAnchoringIsNotPeriodic() throws {
        let chatView = try source("Sources/DS4Control/Views/ChatView.swift")

        XCTAssertFalse(chatView.contains("startBottomFollow"))
        XCTAssertFalse(chatView.contains("followTask"))
        XCTAssertFalse(chatView.contains("while !Task.isCancelled && viewModel.isStreaming"))
        XCTAssertFalse(chatView.contains("33_000_000"))
    }

    func testTranscriptUsesVirtualizedListInsteadOfLazyStack() throws {
        let chatView = try source("Sources/DS4Control/Views/ChatView.swift")

        XCTAssertFalse(chatView.contains("ScrollViewReader"))
        XCTAssertFalse(chatView.contains("LazyVStack"))
        XCTAssertFalse(chatView.contains(".scrollTo("))
        XCTAssertTrue(chatView.contains("List {"))
    }

    func testStreamingTailFollowUsesAlwaysMountedNativeDriver() throws {
        let chatView = try source("Sources/DS4Control/Views/ChatView.swift")

        XCTAssertTrue(chatView.contains("private struct StreamingTailRevision"))
        XCTAssertTrue(chatView.contains("private var streamingTailRevision: StreamingTailRevision"))
        XCTAssertTrue(chatView.contains("BottomScrollDriver("))
        XCTAssertTrue(chatView.contains(".overlay(alignment: .bottom)"))
        XCTAssertFalse(chatView.contains("BottomScrollSentinel("))
    }

    func testBottomDriverScrollsTranscriptScrollViewToBottom() throws {
        let chatView = try source("Sources/DS4Control/Views/ChatView.swift")

        XCTAssertTrue(chatView.contains("findTranscriptScrollView(from: view)"))
        XCTAssertTrue(chatView.contains("findLargestVerticalScrollView(in:"))
        XCTAssertTrue(chatView.contains("documentView.frame.height - scrollView.contentView.bounds.height"))
        XCTAssertTrue(chatView.contains("scrollView.contentView.scroll(to: point)"))
        XCTAssertTrue(chatView.contains("scrollView.reflectScrolledClipView(scrollView.contentView)"))
    }

    func testNewMessageInsertionUpdatesTailRevisionAndSettlesScroll() throws {
        let chatView = try source("Sources/DS4Control/Views/ChatView.swift")

        XCTAssertTrue(chatView.contains("var messageCount: Int"))
        XCTAssertTrue(chatView.contains("messageCount: viewModel.messages.count"))
        XCTAssertTrue(chatView.contains("rowCountChanged"))
        XCTAssertTrue(chatView.contains("asyncAfter"))
    }

    func testSendingMessageIssuesExplicitBottomSnapRequest() throws {
        let chatView = try source("Sources/DS4Control/Views/ChatView.swift")

        XCTAssertTrue(chatView.contains("@State private var bottomSnapRequest"))
        XCTAssertTrue(chatView.contains("private func submitMessage()"))
        XCTAssertTrue(chatView.contains("bottomSnapRequest &+="))
        XCTAssertTrue(chatView.contains("var snapRequest: Int"))
        XCTAssertTrue(chatView.contains("let snapRequested"))
    }

    func testGeneratingIndicatorDoesNotPublishOnAppearState() throws {
        let chatView = try source("Sources/DS4Control/Views/ChatView.swift")

        XCTAssertFalse(chatView.contains("@State private var animating"))
        XCTAssertFalse(chatView.contains(".onAppear { animating = true }"))
    }
}
