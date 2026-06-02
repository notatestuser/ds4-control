import Foundation

enum Variant: String, CaseIterable, Identifiable, Codable {
    case pro, flash
    var id: String { rawValue }
    var displayName: String { self == .pro ? "V4 Pro" : "V4 Flash" }
    var modelId: String { self == .pro ? "deepseek-v4-pro" : "deepseek-v4-flash" }
    /// Transformer layers (DS4 shape): Pro 61, Flash 43.
    var layers: Int { self == .pro ? 61 : 43 }
    /// KV-cache bytes per context token, summed over layers. Measured via
    /// scripts/flash-mem-harness.sh: ds4 reports ~16,023 MiB of context buffers for Flash at
    /// 1M tokens (~391 B/tok/layer) — well under the old fp32 theoretical estimate (640).
    var kvBytesPerToken: Int { layers * 391 }
    /// Context ceiling: both variants support a full 1M-token context window.
    var ctxCeiling: Int { 1_000_000 }
}

enum Quant {
    case proImatrix, q4Imatrix, q2Imatrix, q2q4Imatrix

    /// Concrete quant for a variant. Pro is always `pro-imatrix`; Flash follows the
    /// user-selected `FlashQuant` (default `q2-q4-imatrix`).
    static func `for`(_ variant: Variant, flashQuant: FlashQuant) -> Quant {
        variant == .pro ? .proImatrix : flashQuant.quant
    }

    /// Argument passed to `download_model.sh`.
    var arg: String {
        switch self {
        case .proImatrix: return "pro-imatrix"
        case .q4Imatrix: return "q4-imatrix"
        case .q2Imatrix: return "q2-imatrix"
        case .q2q4Imatrix: return "q2-q4-imatrix"
        }
    }

    /// Exact GGUF filename produced by `download_model.sh` (under $DS4_GGUF_DIR / gguf).
    var ggufFilename: String {
        switch self {
        case .proImatrix:
            return "DeepSeek-V4-Pro-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-Instruct-imatrix.gguf"
        case .q4Imatrix:
            return
                "DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-imatrix.gguf"
        case .q2Imatrix:
            return "DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix.gguf"
        case .q2q4Imatrix:
            return
                "DeepSeek-V4-Flash-Layers37-42Q4KExperts-OtherExpertLayersIQ2XXSGateUp-Q2KDown-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-fixed.gguf"
        }
    }

    /// Approx resident weights, GiB (mmap'd GGUF ≈ file size).
    var weightsGiB: Double {
        switch self {
        case .proImatrix: return 432
        case .q4Imatrix: return 153
        case .q2Imatrix: return 81
        case .q2q4Imatrix: return 91
        }
    }
}

/// User-selectable V4 Flash quant (Settings). Maps to a concrete `Quant`; V4 Pro is always
/// `pro-imatrix` and ignores this. Declared smallest→largest so the picker orders naturally.
enum FlashQuant: String, CaseIterable, Identifiable, Codable {
    case q2 = "q2-imatrix"
    case q2q4 = "q2-q4-imatrix"
    case q4 = "q4-imatrix"
    var id: String { rawValue }
    var quant: Quant {
        switch self {
        case .q2: return .q2Imatrix
        case .q2q4: return .q2q4Imatrix
        case .q4: return .q4Imatrix
        }
    }
    /// Picker label: internal key + approximate resident size, e.g. "q2-q4-imatrix · ~91 GiB".
    var label: String { "\(rawValue) · ~\(Int(quant.weightsGiB)) GiB" }
}
