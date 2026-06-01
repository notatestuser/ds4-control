import Foundation

/// One event from the chat stream. Text deltas carry assistant content; the
/// trailing `usage` event carries server-authoritative token counts (emitted
/// only when the request opts in via `stream_options.include_usage`).
enum ChatStreamEvent: Equatable {
    case text(String)
    case usage(completionTokens: Int, promptTokens: Int, totalTokens: Int)
}
