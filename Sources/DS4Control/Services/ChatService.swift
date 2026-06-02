import Foundation

/// Streams a chat completion from ds4-server.
///
/// The raw SSE *line* source is injectable (`lineSource`) so tests can feed
/// canned lines with no sockets, mirroring `SupervisorService.serverProbe`.
/// In production the line source is `URLSession.bytes(for:)`.
struct ChatService {
    enum ChatError: Error, Equatable {
        case badStatus(Int)
    }

    /// Produces raw SSE lines for a built request. Injected for determinism.
    var lineSource: (URLRequest) -> AsyncThrowingStream<String, Error>

    init(lineSource: @escaping (URLRequest) -> AsyncThrowingStream<String, Error> = ChatService.urlSessionLineSource) {
        self.lineSource = lineSource
    }

    /// Streams assistant content deltas (and a trailing usage event) for the conversation.
    func stream(port: Int, model: String, messages: [ChatMessage], thinkMax: Bool) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let request = Self.makeRequest(port: port, model: model, messages: messages, thinkMax: thinkMax)
        let lines = lineSource(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lines {
                        switch ChatSSEParser.parse(line: line) {
                        case .delta(let text):
                            continuation.yield(.text(text))
                        case .reasoning(let text):
                            continuation.yield(.reasoning(text))
                        case .usage(let completion, let prompt, let total):
                            continuation.yield(
                                .usage(completionTokens: completion, promptTokens: prompt, totalTokens: total))
                        case .done:
                            continuation.finish()
                            return
                        case .ignored:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func makeRequest(port: Int, model: String, messages: [ChatMessage], thinkMax: Bool) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Think Max requires thinking on + reasoning_effort "max" (ds4 honors only "max"); it then
        // engages when the server --ctx ≥ 393,216. Off keeps the chat's fast non-thinking path.
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role == .user ? "user" : "assistant", "content": $0.content] },
            "temperature": 0.7,
            "max_tokens": 32768,
            "thinking": thinkMax,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if thinkMax { body["reasoning_effort"] = "max" }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Production line source: streams bytes from URLSession, surfacing non-200
    /// responses as `ChatError.badStatus`.
    static func urlSessionLineSource(_ request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        throw ChatError.badStatus(http.statusCode)
                    }
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
