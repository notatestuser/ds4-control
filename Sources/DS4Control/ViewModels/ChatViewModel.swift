import Combine
import Foundation

/// Drives a single chat conversation against ds4-server.
///
/// The streaming source is injected (`streamProvider`) so tests can feed a
/// canned `AsyncThrowingStream` with no sockets or scheduler timing.
@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input: String = ""
    @Published private(set) var isStreaming = false
    @Published private(set) var hasReceivedFirstToken = false
    @Published var errorText: String?

    let model: String
    private let port: () -> Int
    private let streamProvider: (Int, String, [ChatMessage]) -> AsyncThrowingStream<String, Error>
    private var streamTask: Task<Void, Never>?

    init(
        model: String,
        port: @escaping () -> Int,
        streamProvider: @escaping (Int, String, [ChatMessage]) -> AsyncThrowingStream<String, Error>
    ) {
        self.model = model
        self.port = port
        self.streamProvider = streamProvider
    }

    var canSend: Bool {
        !isStreaming && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        messages.append(ChatMessage(role: .user, content: text))
        input = ""
        errorText = nil
        isStreaming = true
        hasReceivedFirstToken = false

        let assistant = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(assistant)
        let assistantID = assistant.id

        let stream = streamProvider(port(), model, messages.dropLast().map { $0 })
        streamTask = Task { [weak self] in
            do {
                for try await delta in stream {
                    guard let self else { return }
                    if !self.hasReceivedFirstToken { self.hasReceivedFirstToken = true }
                    self.appendDelta(delta, to: assistantID)
                }
            } catch {
                self?.errorText = error.localizedDescription
            }
            self?.finish(assistantID)
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        if let last = messages.indices.last, messages[last].isStreaming {
            messages[last].isStreaming = false
        }
        isStreaming = false
    }

    func clear() {
        stop()
        messages.removeAll()
        errorText = nil
    }

    private func appendDelta(_ delta: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content += delta
    }

    private func finish(_ id: UUID) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].isStreaming = false
        }
        isStreaming = false
        streamTask = nil
    }
}
