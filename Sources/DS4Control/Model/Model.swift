import Foundation

/// The runnable models DS4 Control can download and serve. A `Model` fully
/// determines identity, download metadata, feasibility, and per-model capability
/// (SSD streaming, thinking modes). DS4F variants map to the existing `Quant`
/// table; Laguna S 2.1 is its own row (facts measured from the GGUF on disk).
enum Model: String, CaseIterable, Identifiable, Codable {
    case v4Pro
    case v4FlashQ2
    case v4FlashQ2Q4
    case v4FlashQ4
    case lagunaS21

    var id: String { rawValue }

    /// The DS4F quant this model maps to (nil for Laguna — it has no DS4F quant).
    var quant: Quant? {
        switch self {
        case .v4Pro: return .proImatrix
        case .v4FlashQ2: return .q2Imatrix
        case .v4FlashQ2Q4: return .q2q4Imatrix
        case .v4FlashQ4: return .q4Imatrix
        case .lagunaS21: return nil
        }
    }

    var displayName: String {
        switch self {
        case .v4Pro: return "V4 Pro"
        case .v4FlashQ2, .v4FlashQ2Q4, .v4FlashQ4: return "V4 Flash"
        case .lagunaS21: return "Laguna S 2.1"
        }
    }

    /// Picker label: display name + resident size, e.g. "V4 Flash · ~91 GiB".
    var label: String { "\(displayName) · ~\(Int(weightsGiB.rounded())) GiB" }

    var modelId: String {
        switch self {
        case .v4Pro: return "deepseek-v4-pro"
        case .v4FlashQ2, .v4FlashQ2Q4, .v4FlashQ4: return "deepseek-v4-flash"
        case .lagunaS21: return "laguna-s-2.1"
        }
    }

    /// Transformer layers (DS4 shape): Pro 61, Flash 43, Laguna S 48.
    var layers: Int {
        switch self {
        case .v4Pro: return 61
        case .v4FlashQ2, .v4FlashQ2Q4, .v4FlashQ4: return 43
        case .lagunaS21: return 48
        }
    }

    /// Context ceiling: DS4F 1M; Laguna 262,144 (GGUF `laguna.context_length`).
    var ctxCeiling: Int {
        switch self {
        case .lagunaS21: return 262_144
        default: return 1_000_000
        }
    }

    /// Approx resident weights, GiB (mmap'd GGUF ≈ file size; Laguna measured).
    var weightsGiB: Double {
        quant?.weightsGiB ?? 44.95
    }

    /// Routed-expert bytes for the SSD-streaming budget table; nil for Laguna
    /// (SSD streaming not supported there).
    var routedExpertGiB: Double? { quant?.routedExpertGiB }

    var supportsSSDStreaming: Bool { quant != nil }
    /// v1: thinking-mode picker is DS4F-only (Laguna uses native interleaved reasoning).
    var supportsThinkingModes: Bool { quant != nil }

    var downloadRepo: String {
        switch self {
        case .lagunaS21: return "antirez/Laguna-S-2.1-GGUF"
        default: return "antirez/deepseek-v4-gguf"
        }
    }
    var downloadRevision: String { "main" }
    var ggufFilename: String {
        quant?.ggufFilename ?? "laguna-s-2.1-RoutedQ2_K-Last27Q3_K.gguf"
    }

    /// Family launch tweak: Laguna bounds graph scratch on 64 GB-class machines
    /// (measured: prefill 16384 → ~5.9 GiB scratch; 4096 → ~1.5 GiB).
    var defaultPrefillChunk: Int? { self == .lagunaS21 ? 4096 : nil }
}
