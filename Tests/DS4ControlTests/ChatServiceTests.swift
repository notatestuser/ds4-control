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

    func testStreamsDeltasUntilDone() async throws {
        let service = ChatService(
            lineSource: fixedLines([
                #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#,
                #"data: {"choices":[{"delta":{"content":"lo"}}]}"#,
                "data: [DONE]",
                #"data: {"choices":[{"delta":{"content":"ignored"}}]}"#,
            ])
        )
        var collected: [String] = []
        for try await delta in service.stream(port: 8000, model: "deepseek-v4-pro", messages: []) {
            collected.append(delta)
        }
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
        var collected: [String] = []
        for try await delta in service.stream(port: 8000, model: "m", messages: []) {
            collected.append(delta)
        }
        XCTAssertEqual(collected, ["x"])
    }

    func testFinishesWhenStreamEndsWithoutDone() async throws {
        let service = ChatService(
            lineSource: fixedLines([
                #"data: {"choices":[{"delta":{"content":"a"}}]}"#
            ])
        )
        var collected: [String] = []
        for try await delta in service.stream(port: 8000, model: "m", messages: []) {
            collected.append(delta)
        }
        XCTAssertEqual(collected, ["a"])
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
            for try await delta in service.stream(port: 8000, model: "m", messages: []) {
                collected.append(delta)
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
            messages: [ChatMessage(role: .user, content: "hi")]
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:9001/v1/chat/completions")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "deepseek-v4-pro")
        XCTAssertEqual(json["temperature"] as? Double, 0.7)
        XCTAssertEqual(json["max_tokens"] as? Int, 32768)
        XCTAssertEqual(json["thinking"] as? Bool, false)
        XCTAssertEqual(json["stream"] as? Bool, true)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.first?["role"], "user")
        XCTAssertEqual(messages.first?["content"], "hi")
    }
}
