import Foundation

enum ChatRole {
    case user
    case assistant
}

/// Generation performance for one assistant reply. `nil` fields render as omitted.
struct GenerationStats: Equatable {
    var ttftSeconds: Double?
    var decodeSeconds: Double?
    var completionTokens: Int?

    /// Server-authoritative completion tokens over the client-measured decode window.
    var tokensPerSecond: Double? {
        guard let completionTokens, let d = decodeSeconds, d > 0 else { return nil }
        return Double(completionTokens) / d
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    var role: ChatRole
    var content: String
    /// Think-Max reasoning (ds4's `reasoning_content`), kept separate from `content` so the UI
    /// can hide it in a collapsed section. Empty when the reply carried no reasoning.
    var thinking: String
    var isStreaming: Bool
    var stats: GenerationStats?

    init(id: UUID = UUID(), role: ChatRole, content: String, thinking: String = "", isStreaming: Bool = false, stats: GenerationStats? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.thinking = thinking
        self.isStreaming = isStreaming
        self.stats = stats
    }
}
