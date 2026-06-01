import Combine
import XCTest

@testable import DS4Control

@MainActor
final class ChatViewModelTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    /// Builds a VM whose stream yields the given text deltas (and an optional
    /// trailing usage event) then finishes.
    private func makeViewModel(
        deltas: [String],
        usage: (completion: Int, prompt: Int, total: Int)? = nil,
        error: Error? = nil
    ) -> ChatViewModel {
        ChatViewModel(
            model: "deepseek-v4-pro",
            port: { 8000 },
            streamProvider: { _, _, _ in
                AsyncThrowingStream { continuation in
                    for delta in deltas { continuation.yield(.text(delta)) }
                    if let usage {
                        continuation.yield(
                            .usage(
                                completionTokens: usage.completion, promptTokens: usage.prompt, totalTokens: usage.total
                            ))
                    }
                    if let error { continuation.finish(throwing: error) } else { continuation.finish() }
                }
            }
        )
    }

    /// Awaits the streaming completion deterministically (driven by data, not a timer):
    /// fulfils once `isStreaming` flips back to false.
    private func awaitStreamCompletion(_ viewModel: ChatViewModel) async {
        let expectation = expectation(description: "stream finished")
        viewModel.$isStreaming
            .dropFirst()
            .filter { !$0 }
            .first()
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)
        await fulfillment(of: [expectation], timeout: 5)
    }

    func testSendAppendsUserAndAssistantMessages() async {
        let viewModel = makeViewModel(deltas: ["Hi", " there"])
        viewModel.input = "Hello"
        viewModel.send()
        await awaitStreamCompletion(viewModel)

        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages[0].role, .user)
        XCTAssertEqual(viewModel.messages[0].content, "Hello")
        XCTAssertEqual(viewModel.messages[1].role, .assistant)
        XCTAssertEqual(viewModel.messages[1].content, "Hi there")
        XCTAssertFalse(viewModel.messages[1].isStreaming)
        XCTAssertFalse(viewModel.isStreaming)
        XCTAssertTrue(viewModel.input.isEmpty)
    }

    func testFirstTokenFlagSet() async {
        let viewModel = makeViewModel(deltas: ["x"])
        XCTAssertFalse(viewModel.hasReceivedFirstToken)
        viewModel.input = "go"
        viewModel.send()
        await awaitStreamCompletion(viewModel)
        XCTAssertTrue(viewModel.hasReceivedFirstToken)
    }

    func testSendIgnoresEmptyInput() {
        let viewModel = makeViewModel(deltas: ["x"])
        viewModel.input = "   "
        viewModel.send()
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertFalse(viewModel.isStreaming)
    }

    func testCanSendGating() {
        let viewModel = makeViewModel(deltas: [])
        XCTAssertFalse(viewModel.canSend)
        viewModel.input = "hi"
        XCTAssertTrue(viewModel.canSend)
    }

    func testErrorSurfacesAndStopsStreaming() async {
        struct Boom: Error {}
        let viewModel = makeViewModel(deltas: ["partial"], error: Boom())
        viewModel.input = "go"
        viewModel.send()
        await awaitStreamCompletion(viewModel)
        XCTAssertNotNil(viewModel.errorText)
        XCTAssertFalse(viewModel.isStreaming)
        XCTAssertEqual(viewModel.messages.last?.content, "partial")
    }

    func testClearRemovesMessages() async {
        let viewModel = makeViewModel(deltas: ["x"])
        viewModel.input = "go"
        viewModel.send()
        await awaitStreamCompletion(viewModel)
        viewModel.clear()
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNil(viewModel.errorText)
    }

    func testStreamingDeltasMutateLastMessage() async {
        let viewModel = makeViewModel(deltas: ["a", "b", "c"])
        viewModel.input = "go"
        viewModel.send()
        await awaitStreamCompletion(viewModel)
        XCTAssertEqual(viewModel.messages.last?.content, "abc")
    }

    func testUsagePopulatesStatsAndContextUsage() async {
        let viewModel = makeViewModel(deltas: ["Hello"], usage: (completion: 90, prompt: 100, total: 190))
        viewModel.input = "go"
        viewModel.send()
        await awaitStreamCompletion(viewModel)
        let stats = viewModel.messages.last?.stats
        XCTAssertEqual(stats?.completionTokens, 90)
        XCTAssertNotNil(stats?.ttftSeconds)
        XCTAssertNotNil(stats?.decodeSeconds)
        XCTAssertEqual(viewModel.contextUsedTokens, 190)
    }

    func testStatsWithoutUsageHasTimingButNoTokenCount() async {
        let viewModel = makeViewModel(deltas: ["a", "b"])
        viewModel.input = "go"
        viewModel.send()
        await awaitStreamCompletion(viewModel)
        XCTAssertNotNil(viewModel.messages.last?.stats)
        XCTAssertNil(viewModel.messages.last?.stats?.completionTokens)
        XCTAssertEqual(viewModel.contextUsedTokens, 0)
    }

    func testClearResetsContextUsage() async {
        let viewModel = makeViewModel(deltas: ["x"], usage: (completion: 5, prompt: 10, total: 15))
        viewModel.input = "go"
        viewModel.send()
        await awaitStreamCompletion(viewModel)
        XCTAssertEqual(viewModel.contextUsedTokens, 15)
        viewModel.clear()
        XCTAssertEqual(viewModel.contextUsedTokens, 0)
    }
}
