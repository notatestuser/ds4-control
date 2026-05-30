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

    /// Streams assistant content deltas for the given conversation.
    func stream(port: Int, model: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        let request = Self.makeRequest(port: port, model: model, messages: messages)
        let lines = lineSource(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lines {
                        switch ChatSSEParser.parse(line: line) {
                        case .delta(let text):
                            continuation.yield(text)
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

    static func makeRequest(port: Int, model: String, messages: [ChatMessage]) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role == .user ? "user" : "assistant", "content": $0.content] },
            "temperature": 0.7,
            "max_tokens": 32768,
            "thinking": false,
            "stream": true,
        ]
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
