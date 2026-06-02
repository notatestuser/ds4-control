import Foundation

/// One event from the chat stream. Text deltas carry assistant content; reasoning
/// deltas carry Think-Max reasoning (ds4's `reasoning_content`); the trailing `usage`
/// event carries server-authoritative token counts (emitted only when the request opts
/// in via `stream_options.include_usage`).
enum ChatStreamEvent: Equatable {
    case text(String)
    case reasoning(String)
    case usage(completionTokens: Int, promptTokens: Int, totalTokens: Int)
}
