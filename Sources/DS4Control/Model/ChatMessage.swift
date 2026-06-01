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
    var isStreaming: Bool
    var stats: GenerationStats?

    init(id: UUID = UUID(), role: ChatRole, content: String, isStreaming: Bool = false, stats: GenerationStats? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.stats = stats
    }
}
