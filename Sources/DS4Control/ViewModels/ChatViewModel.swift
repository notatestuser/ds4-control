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
    private var flushTask: Task<Void, Never>?

    // Thinking flushes on a coarser cadence than content: reasoning live-ness matters less
    // and Max-Think reasoning can be long. Content flushes every tick (~33ms); thinking
    // every Nth tick (~264ms).
    private var flushTickCount = 0
    private static let thinkingFlushEveryNTicks = 8  // 33ms × 8 ≈ 264ms

    // Single-in-flight guard (adaptive backpressure): a flush tick landing right after a
    // mutation treats the prior render as still settling and skips, clearing the flag so the
    // next tick resumes. SwiftUI has no literal "render finished" callback — this cooldown is
    // the serialization boundary. finish()/stop() bypass it with `force: true` so the final
    // tokens always land. Internal (with the cadence members) for deterministic testing.
    private(set) var updateInFlight = false

    // ID of the message currently being streamed — captured at `send()` time so the flush
    // loop knows which row to mutate. Nil when no stream is active. Internal so the guard /
    // cadence tests can drive a deterministic streaming row.
    var streamingMessageID: UUID?

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
                self?.tickFlush()
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
        applyPendingDeltas(includeThinking: true, force: true)
        streamTask?.cancel()
        streamTask = nil
        flushTask?.cancel()
        flushTask = nil
        streamingMessageID = nil
        flushTickCount = 0
        updateInFlight = false
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
    func bufferContentDelta(_ delta: String) {
        pendingContentDelta += delta
    }

    /// Append an incoming reasoning delta to the pending buffer. Same
    /// throttle contract as `bufferContentDelta(_:)`.
    func bufferThinkingDelta(_ delta: String) {
        pendingThinkingDelta += delta
    }

    /// Timer entry point. Content flushes every tick; thinking every Nth tick. Hosts the
    /// single-in-flight cooldown: a tick landing right after a mutation is skipped, clearing
    /// the flag so the next tick resumes.
    @MainActor
    func tickFlush() {
        if updateInFlight {
            updateInFlight = false
            return
        }
        flushTickCount &+= 1
        let includeThinking = flushTickCount % Self.thinkingFlushEveryNTicks == 0
        applyPendingDeltas(includeThinking: includeThinking, force: false)
    }

    /// Drain the pending buffers into the streaming message's row. Skips while an update is
    /// in flight unless `force` (finish()/stop() use `force: true` to drain synchronously).
    /// A real mutation marks in-flight; the next `tickFlush` clears it (cooldown).
    @MainActor
    func applyPendingDeltas(includeThinking: Bool, force: Bool) {
        if !force && updateInFlight { return }
        guard let id = streamingMessageID,
            let index = messages.firstIndex(where: { $0.id == id })
        else { return }
        var mutated = false
        if !pendingContentDelta.isEmpty {
            messages[index].content += pendingContentDelta
            pendingContentDelta = ""
            mutated = true
        }
        if includeThinking && !pendingThinkingDelta.isEmpty {
            messages[index].thinking += pendingThinkingDelta
            pendingThinkingDelta = ""
            mutated = true
        }
        guard mutated else { return }
        if !force { updateInFlight = true }  // cleared by the next tickFlush (cooldown)
    }

    private func finish(_ id: UUID) {
        // Force-flush any pending deltas before mutating the message one
        // last time, so no token is lost when the stream ends between flush
        // ticks. Also cancel the flush loop — it has no work left.
        applyPendingDeltas(includeThinking: true, force: true)
        flushTask?.cancel()
        flushTask = nil
        streamingMessageID = nil
        flushTickCount = 0
        updateInFlight = false

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
