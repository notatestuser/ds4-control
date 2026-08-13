import Foundation

/// The chat's thinking level. ds4 collapses every OpenAI-style effort name to three real
/// modes, so the control has three honest rungs: `.off` ("Instant" — no thinking),
/// `.standard` (thinking on, no effort prefix — works at any context size), `.max`
/// (thinking on + `reasoning_effort: "max"`, which ds4 honors only at context ≥ 393,216).
enum ThinkingMode: String, CaseIterable, Identifiable, Codable {
    case off, standard, max
    var id: String { rawValue }
    /// Segment label for the Thinking: picker.
    var label: String {
        switch self {
        case .off: return "Instant"
        case .standard: return "Standard"
        case .max: return "Max Think"
        }
    }
}

/// Result of `AppState.requestThinkingMode`: the mode was applied, or the caller must
/// first ask the user about bumping the context to 393,216 (`.max` below the floor), or
/// Max Think is unavailable on this machine tier.
enum ThinkingModeGate { case applied, needsCtxBump, unavailable }
