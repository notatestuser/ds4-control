import Foundation

enum ChatRole {
    case user
    case assistant
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    var role: ChatRole
    var content: String
    var isStreaming: Bool

    init(id: UUID = UUID(), role: ChatRole, content: String, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
    }
}
