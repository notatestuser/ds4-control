import Foundation

enum Variant: String, CaseIterable, Identifiable, Codable {
    case pro, flash
    var id: String { rawValue }
    var displayName: String { self == .pro ? "V4 Pro" : "V4 Flash" }
    var modelId: String { self == .pro ? "deepseek-v4-pro" : "deepseek-v4-flash" }
    /// Transformer layers (DS4 shape): Pro 61, Flash 43.
    var layers: Int { self == .pro ? 61 : 43 }
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

    /// The ds4 model-target identifier for this quant (e.g. `pro-q2-imatrix`).
    var arg: String {
        switch self {
        // ds4 renamed the single-file Pro target `pro-imatrix` → `pro-q2-imatrix`.
        case .proImatrix: return "pro-q2-imatrix"
        case .q4Imatrix: return "q4-imatrix"
        case .q2Imatrix: return "q2-imatrix"
        case .q2q4Imatrix: return "q2-q4-imatrix"
        }
    }

    /// Exact GGUF filename the downloader fetches (under $DS4_GGUF_DIR / gguf).
    /// Flash names are antirez's official `-0731` builds (DeepSeek-V4-Flash-0731,
    /// antirez/ds4#635) — same quant recipes and byte sizes as the preview builds they
    /// replace, so `weightsGiB` and the RAM tiers are unchanged.
    var ggufFilename: String {
        switch self {
        case .proImatrix:
            return "DeepSeek-V4-Pro-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-Instruct-imatrix.gguf"
        case .q4Imatrix:
            return
                "DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-imatrix-0731.gguf"
        case .q2Imatrix:
            return "DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf"
        case .q2q4Imatrix:
            return
                "DeepSeek-V4-Flash-Layers37-42Q4KExperts-OtherExpertLayersIQ2XXSGateUp-Q2KDown-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-fixed-0731.gguf"
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

    /// Exact GGUF byte size. Feasibility uses this instead of the rounded display
    /// value above so the wired-limit gate never understates resident weights.
    var ggufBytes: Int {
        switch self {
        case .proImatrix: return 464_627_334_560
        case .q4Imatrix: return 164_633_502_592
        case .q2Imatrix: return 86_720_111_488
        case .q2q4Imatrix: return 97_591_747_456
        }
    }

    /// Pre-0731 ("preview") Flash GGUF filenames this app used to download. Referenced only
    /// by the one-time migration cleanup; Pro never had a preview build.
    static let legacyPreviewFilenames = [
        "DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix.gguf",
        "DeepSeek-V4-Flash-Layers37-42Q4KExperts-OtherExpertLayersIQ2XXSGateUp-Q2KDown-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-fixed.gguf",
        "DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-imatrix.gguf",
    ]
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
    /// Picker label: weights generation + internal key + approximate resident size,
    /// e.g. "0731-q2-q4-imatrix · ~91 GiB". All Flash quants are the 0731 builds.
    var label: String { "0731-\(rawValue) · ~\(Int(quant.weightsGiB)) GiB" }
}
