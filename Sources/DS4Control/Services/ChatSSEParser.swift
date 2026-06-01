import Foundation

/// Pure parser for ds4-server's SSE chat stream. No I/O — given a single SSE
/// line it returns the next event, so the streaming service and unit tests can
/// share identical decode logic.
enum ChatSSEParser {
    enum Event: Equatable {
        case delta(String)
        case usage(completionTokens: Int, promptTokens: Int, totalTokens: Int)
        case done
        case ignored
    }

    /// Decode one already-split SSE line (no trailing newline).
    /// - Recognises `data: [DONE]` as the terminator.
    /// - Extracts the trailing `usage` chunk (token counts) when present.
    /// - Extracts `choices[0].delta.content` from `data: {json}` lines.
    /// - Blank lines, comments and malformed payloads are `.ignored`.
    static func parse(line: String) -> Event {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return .ignored }

        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard !payload.isEmpty, let data = payload.data(using: .utf8) else { return .ignored }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .ignored
        }

        // The usage chunk carries `"choices":[]` plus a `usage` object, so it must
        // be matched before the choices/content path below.
        if let usage = root["usage"] as? [String: Any],
            let completion = usage["completion_tokens"] as? Int,
            let prompt = usage["prompt_tokens"] as? Int
        {
            let total = usage["total_tokens"] as? Int ?? (prompt + completion)
            return .usage(completionTokens: completion, promptTokens: prompt, totalTokens: total)
        }

        guard
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let delta = first["delta"] as? [String: Any],
            let content = delta["content"] as? String,
            !content.isEmpty
        else {
            return .ignored
        }
        return .delta(content)
    }
}
