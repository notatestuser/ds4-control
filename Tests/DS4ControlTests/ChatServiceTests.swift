import XCTest

@testable import DS4Control

final class ChatServiceTests: XCTestCase {
    private func fixedLines(_ lines: [String]) -> (URLRequest) -> AsyncThrowingStream<String, Error> {
        { _ in
            AsyncThrowingStream { continuation in
                for line in lines { continuation.yield(line) }
                continuation.finish()
            }
        }
    }

    /// Collects the text payloads from a `ChatStreamEvent` stream.
    private func collectText(_ stream: AsyncThrowingStream<ChatStreamEvent, Error>) async throws -> [String] {
        var collected: [String] = []
        for try await event in stream {
            if case .text(let t) = event { collected.append(t) }
        }
        return collected
    }

    func testStreamsDeltasUntilDone() async throws {
        let service = ChatService(
            lineSource: fixedLines([
                #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#,
                #"data: {"choices":[{"delta":{"content":"lo"}}]}"#,
                "data: [DONE]",
                #"data: {"choices":[{"delta":{"content":"ignored"}}]}"#,
            ])
        )
        let collected = try await collectText(service.stream(port: 8000, model: "deepseek-v4-pro", messages: [], thinkMax: false))
        XCTAssertEqual(collected, ["Hel", "lo"])
    }

    func testIgnoresBlankAndCommentLines() async throws {
        let service = ChatService(
            lineSource: fixedLines([
                "",
                ": keep-alive",
                #"data: {"choices":[{"delta":{"content":"x"}}]}"#,
                "data: [DONE]",
            ])
        )
        let collected = try await collectText(service.stream(port: 8000, model: "m", messages: [], thinkMax: false))
        XCTAssertEqual(collected, ["x"])
    }

    func testFinishesWhenStreamEndsWithoutDone() async throws {
        let service = ChatService(
            lineSource: fixedLines([
                #"data: {"choices":[{"delta":{"content":"a"}}]}"#
            ])
        )
        let collected = try await collectText(service.stream(port: 8000, model: "m", messages: [], thinkMax: false))
        XCTAssertEqual(collected, ["a"])
    }

    func testSurfacesUsageEvent() async throws {
        let service = ChatService(
            lineSource: fixedLines([
                #"data: {"choices":[{"delta":{"content":"hi"}}]}"#,
                #"data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}"#,
                "data: [DONE]",
            ])
        )
        var events: [ChatStreamEvent] = []
        for try await event in service.stream(port: 8000, model: "m", messages: [], thinkMax: false) {
            events.append(event)
        }
        XCTAssertEqual(events, [.text("hi"), .usage(completionTokens: 2, promptTokens: 10, totalTokens: 12)])
    }

    func testPropagatesError() async {
        struct Boom: Error {}
        let service = ChatService(lineSource: { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(#"data: {"choices":[{"delta":{"content":"a"}}]}"#)
                continuation.finish(throwing: Boom())
            }
        })
        var collected: [String] = []
        do {
            for try await event in service.stream(port: 8000, model: "m", messages: [], thinkMax: false) {
                if case .text(let t) = event { collected.append(t) }
            }
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(collected, ["a"])
        }
    }

    func testRequestBodyShape() throws {
        let request = ChatService.makeRequest(
            port: 9001,
            model: "deepseek-v4-pro",
            messages: [ChatMessage(role: .user, content: "hi")],
            thinkMax: false
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:9001/v1/chat/completions")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "deepseek-v4-pro")
        XCTAssertEqual(json["temperature"] as? Double, 0.7)
        XCTAssertEqual(json["max_tokens"] as? Int, 32768)
        XCTAssertEqual(json["thinking"] as? Bool, false)
        XCTAssertNil(json["reasoning_effort"])  // off → no max effort
        XCTAssertEqual(json["stream"] as? Bool, true)
        let streamOptions = try XCTUnwrap(json["stream_options"] as? [String: Any])
        XCTAssertEqual(streamOptions["include_usage"] as? Bool, true)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.first?["role"], "user")
        XCTAssertEqual(messages.first?["content"], "hi")
    }

    func testThinkMaxRequestEnablesMaxEffort() throws {
        let request = ChatService.makeRequest(
            port: 9001, model: "deepseek-v4-flash",
            messages: [ChatMessage(role: .user, content: "hi")], thinkMax: true)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["thinking"] as? Bool, true)  // thinking on so Think Max can apply
        XCTAssertEqual(json["reasoning_effort"] as? String, "max")  // ds4 honors only "max"
    }
}
