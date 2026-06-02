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
    @Published private(set) var contextUsedTokens = 0
    @Published var errorText: String?

    let model: String
    private let port: () -> Int
    private let streamProvider: (Int, String, [ChatMessage]) -> AsyncThrowingStream<ChatStreamEvent, Error>
    private var streamTask: Task<Void, Never>?

    // In-flight timing/usage for the current reply (MainActor-isolated state, not
    // captured locals — mutating captured vars inside the Task closure won't compile).
    private var genStart: Date?
    private var genFirstToken: Date?
    private var genCompletionTokens: Int?
    private var genTotalTokens: Int?

    // Streaming throttle: every token from ds4-server triggers a `@Published`
    // mutation on `messages.last.content`, which kicks the AttributeGraph
    // walk. With ~50 bubbles in the chat window × ~50 tokens/sec, that's
    // 2,500 measurements/sec just from the streaming content. We buffer
    // incoming deltas in these strings and flush them on a 33ms timer (≈30Hz)
    // — the AttributeGraph walk drops 1.5×, no visible streaming delay (33ms
    // is well under one display frame), and the final token still flushes
    // synchronously in `finish(_:)` so nothing is dropped on stream end.
    //
    // The flush task is a long-lived polling loop on the main actor (it hops
    // in via MainActor.run for each sleep+flush iteration). It exists only
    // while a stream is active: started in `send()`, cancelled in `finish(_:)`
    // / `stop()`.
    private static let streamingFlushIntervalNanos: UInt64 = 33_000_000  // 33ms
    private var pendingContentDelta: String = ""
    private var pendingThinkingDelta: String = ""
    private var hasPendingDelta: Bool {
        !pendingContentDelta.isEmpty || !pendingThinkingDelta.isEmpty
    }
    private var flushTask: Task<Void, Never>?

    // ID of the message currently being streamed — captured at `send()` time
    // so the flush loop knows which row to mutate. Nil when no stream is active.
    private var streamingMessageID: UUID?

    init(
        model: String,
        port: @escaping () -> Int,
        streamProvider: @escaping (Int, String, [ChatMessage]) -> AsyncThrowingStream<ChatStreamEvent, Error>
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

        genStart = Date()
        genFirstToken = nil
        genCompletionTokens = nil
        genTotalTokens = nil

        let assistant = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(assistant)
        let assistantID = assistant.id
        streamingMessageID = assistantID

        // Start the 33ms flush loop. Polling sleeps on a detached task and
        // hops back to the main actor for each flush; the loop ends when
        // `finish(_:)` or `stop()` cancels `flushTask`.
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.streamingFlushIntervalNanos)
                if Task.isCancelled { return }
                await self?.flushPendingDeltas()
            }
        }

        let stream = streamProvider(port(), model, messages.dropLast().map { $0 })
        streamTask = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self else { return }
                    switch event {
                    case .text(let delta):
                        if self.genFirstToken == nil { self.genFirstToken = Date() }
                        if !self.hasReceivedFirstToken { self.hasReceivedFirstToken = true }
                        self.bufferContentDelta(delta)
                    case .reasoning(let delta):
                        // Reasoning streams before the answer; the first reasoning token is TTFT.
                        if self.genFirstToken == nil { self.genFirstToken = Date() }
                        if !self.hasReceivedFirstToken { self.hasReceivedFirstToken = true }
                        self.bufferThinkingDelta(delta)
                    case .usage(let completion, _, let total):
                        self.genCompletionTokens = completion
                        self.genTotalTokens = total
                    }
                }
            } catch {
                self?.errorText = error.localizedDescription
            }
            self?.finish(assistantID)
        }
    }

    func stop() {
        // Flush any pending content the user would otherwise lose on cancel —
        // a 33ms buffer at most, but the user pressed Stop and expects to
        // see what was generated.
        flushPendingDeltas()
        streamTask?.cancel()
        streamTask = nil
        flushTask?.cancel()
        flushTask = nil
        streamingMessageID = nil
        pendingContentDelta = ""
        pendingThinkingDelta = ""
        if let last = messages.indices.last, messages[last].isStreaming {
            messages[last].isStreaming = false
        }
        isStreaming = false
    }

    func clear() {
        stop()
        messages.removeAll()
        errorText = nil
        contextUsedTokens = 0
    }

    /// Append an incoming content delta to the pending buffer. Does NOT
    /// mutate `messages` — the flush loop applies the buffer every 33ms.
    private func bufferContentDelta(_ delta: String) {
        pendingContentDelta += delta
    }

    /// Append an incoming reasoning delta to the pending buffer. Same
    /// throttle contract as `bufferContentDelta(_:)`.
    private func bufferThinkingDelta(_ delta: String) {
        pendingThinkingDelta += delta
    }

    /// Drain the pending buffers into the streaming message's row. Called
    /// from the flush loop on the main actor. No-op if there's nothing
    /// pending (the common case between deltas).
    @MainActor
    private func flushPendingDeltas() {
        guard hasPendingDelta, let id = streamingMessageID,
            let index = messages.firstIndex(where: { $0.id == id })
        else { return }
        if !pendingContentDelta.isEmpty {
            messages[index].content += pendingContentDelta
            pendingContentDelta = ""
        }
        if !pendingThinkingDelta.isEmpty {
            messages[index].thinking += pendingThinkingDelta
            pendingThinkingDelta = ""
        }
    }

    private func finish(_ id: UUID) {
        // Force-flush any pending deltas before mutating the message one
        // last time, so no token is lost when the stream ends between flush
        // ticks. Also cancel the flush loop — it has no work left.
        flushPendingDeltas()
        flushTask?.cancel()
        flushTask = nil
        streamingMessageID = nil

        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].isStreaming = false
            if let start = genStart, let first = genFirstToken {
                messages[index].stats = GenerationStats(
                    ttftSeconds: first.timeIntervalSince(start),
                    decodeSeconds: Date().timeIntervalSince(first),
                    completionTokens: genCompletionTokens
                )
            }
        }
        if let total = genTotalTokens { contextUsedTokens = total }
        isStreaming = false
        streamTask = nil
    }
}
