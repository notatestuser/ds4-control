import Foundation

enum Variant: String, CaseIterable, Identifiable, Codable {
    case pro, flash, flash41  // flash = V4 Flash 0731 GA; flash41 = DeepSeek V4.1 Flash
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .pro: return "V4 Pro"
        case .flash: return "V4 Flash"
        case .flash41: return "V4.1 Flash"
        }
    }
    var modelId: String {
        switch self {
        case .pro: return "deepseek-v4-pro"
        case .flash: return "deepseek-v4-flash"
        case .flash41: return "deepseek-v4.1-flash"
        }
    }
    /// Generation-specific disk KV namespace. Checkpoints depend on the exact model
    /// weights, so preview and GA releases must never share a cache directory.
    var kvCacheDirectoryName: String {
        switch self {
        case .pro: return "kv-pro-0813"
        case .flash: return "kv-flash-0731"
        case .flash41: return "kv-flash-41"
        }
    }
    /// Transformer layers (DS4 shape): Pro 61, Flash 43, V4.1 Flash 40.
    var layers: Int {
        switch self {
        case .pro: return 61
        case .flash: return 43
        case .flash41: return 40
        }
    }
    /// Context ceiling. Pro/Flash expose the full 1M window; V4.1's GGUF declares
    /// `max_position_embeddings` = 1,048,576 exactly.
    var ctxCeiling: Int { self == .flash41 ? 1_048_576 : 1_000_000 }
}

/// One transport file of a quant's download. V4.1 Q4 ships as two joined parts.
struct QuantPart: Equatable {
    let filename: String
    let bytes: Int64
    /// Published SHA-256, verified after download (and before joining).
    let sha256: String?
}

enum Quant {
    case proImatrix, q4Imatrix, q2Imatrix, q2q4Imatrix, q41Q2, q41Q4

    /// Concrete quant for a variant. Pro is always `pro-imatrix`; Flash follows the
    /// user-selected `FlashQuant` (default `q2-q4-imatrix`). V4.1 Flash must go through
    /// `QuantSelection` so its own quant picker is honored.
    static func `for`(_ variant: Variant, flashQuant: FlashQuant) -> Quant {
        switch variant {
        case .pro: return .proImatrix
        case .flash: return flashQuant.quant
        case .flash41: preconditionFailure("V4.1 Flash quants resolve through QuantSelection")
        }
    }

    static func `for`(_ selection: QuantSelection) -> Quant { selection.quant }

    /// HuggingFace repo hosting this quant's GGUF(s).
    var repo: String {
        switch self {
        case .proImatrix, .q4Imatrix, .q2Imatrix, .q2q4Imatrix: return "antirez/deepseek-v4-gguf"
        case .q41Q2, .q41Q4: return "antirez/deepseek-v4.1-flash-gguf"
        }
    }

    /// The ds4 model-target identifier for this quant (e.g. `pro-q2-imatrix`).
    var arg: String {
        switch self {
        // ds4 renamed the single-file Pro target `pro-imatrix` → `pro-q2-imatrix`.
        case .proImatrix: return "pro-q2-imatrix"
        case .q4Imatrix: return "q4-imatrix"
        case .q2Imatrix: return "q2-imatrix"
        case .q2q4Imatrix: return "q2-q4-imatrix"
        case .q41Q2: return "ds41f-q2"
        case .q41Q4: return "ds41f-q4"
        }
    }

    /// Exact GGUF filename the downloader fetches (under $DS4_GGUF_DIR / gguf) — the final,
    /// joined name where the download is split. Names are antirez's official GA builds:
    /// Pro 0813, Flash 0731, and V4.1 Flash. The V4/Pro quant recipes and exact byte sizes
    /// carry over from their preview predecessors.
    var ggufFilename: String {
        switch self {
        case .proImatrix:
            return "DeepSeek-V4-Pro-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-Instruct-imatrix-0813.gguf"
        case .q4Imatrix:
            return
                "DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-imatrix-0731.gguf"
        case .q2Imatrix:
            return "DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf"
        case .q2q4Imatrix:
            return
                "DeepSeek-V4-Flash-Layers37-42Q4KExperts-OtherExpertLayersIQ2XXSGateUp-Q2KDown-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-fixed-0731.gguf"
        case .q41Q2:
            return "DeepSeek-V4.1-Flash-Q2.gguf"
        case .q41Q4:
            return "DeepSeek-V4.1-Flash-Q4.gguf"
        }
    }

    /// Approx resident weights, GiB (mmap'd GGUF ≈ file size). For V4.1 this is the
    /// resident main-weight portion only; the disk-only Engram tables stream from the SSD.
    var weightsGiB: Double {
        switch self {
        case .proImatrix: return 432
        case .q4Imatrix: return 153
        case .q2Imatrix: return 81
        case .q2q4Imatrix: return 91
        case .q41Q2: return 152
        case .q41Q4: return 294
        }
    }

    /// Exact GGUF byte size (the joined size for split downloads). Feasibility uses this
    /// instead of the rounded display value above so progress and gates never understate it.
    var ggufBytes: Int {
        switch self {
        case .proImatrix: return 464_627_334_560
        case .q4Imatrix: return 164_633_502_592
        case .q2Imatrix: return 86_720_111_488
        case .q2q4Imatrix: return 97_591_747_456
        case .q41Q2: return 365_713_686_528
        case .q41Q4: return 518_596_067_328
        }
    }

    /// V4.1 only: bytes resident when the model is fully loaded. The GGUF carries
    /// 202,778,032,400 B (two tables: 384,006,168 + 384,016,682 rows × 264 B) of disk-only
    /// Engram rows; ds4 `munmap`s them at load, so the wired working set is the file minus
    /// that constant. nil for V4/Pro (the whole file is resident).
    var residentMainBytes: Int? {
        switch self {
        case .q41Q2, .q41Q4: return ggufBytes - 202_778_032_400
        default: return nil
        }
    }

    /// Whole-file SHA-256 published by upstream, verified after download. nil where
    /// upstream publishes none (V4/Pro artifacts predate digest verification).
    var sha256: String? {
        switch self {
        case .q41Q2: return "1ce6a8f8806205c13330d7ca287bd198331dc5ca35ccc5d8a9a92a188a6f6f42"
        case .q41Q4: return "a5e2e2c3ada4b2e98d9f9e4b50f6d9c2a12c2c96f5da165c07e13aff9264984e"
        default: return nil
        }
    }

    /// Transport files to fetch, in order. Almost all quants are a single file; V4.1 Q4
    /// ships as two parts that must be joined (and each part digest-verified) after download.
    var downloadParts: [QuantPart] {
        switch self {
        case .q41Q4:
            return [
                QuantPart(
                    filename: "DeepSeek-V4.1-Flash-Q4.gguf.part1", bytes: 480_000_000_000,
                    sha256: "6442b1f9224079662c02003c0ef9ef6be6e2aff509510f681dab9e6cc41df246"),
                QuantPart(
                    filename: "DeepSeek-V4.1-Flash-Q4.gguf.part2", bytes: 38_596_067_328,
                    sha256: "7c3e10646c918eeaffbc39305a75ec96117450262c61454ff194cef00d7617f0"),
            ]
        default:
            return [QuantPart(filename: ggufFilename, bytes: Int64(ggufBytes), sha256: sha256)]
        }
    }

    /// Preview GGUF filenames this app used to download. Referenced only by the
    /// generation-versioned migration cleanup.
    static let legacyPreviewFilenames = [
        "DeepSeek-V4-Pro-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-Instruct-imatrix.gguf",
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

/// User-selectable DeepSeek V4.1 Flash quant (Settings). Labels show the resident main
/// weights; both files also carry ~189 GiB of disk-only Engram tables.
enum Flash41Quant: String, CaseIterable, Identifiable, Codable {
    case q2, q4
    var id: String { rawValue }
    var quant: Quant {
        switch self {
        case .q2: return .q41Q2
        case .q4: return .q41Q4
        }
    }
    /// Picker label: weights key + resident main weights + file size on disk (the file also
    /// carries ~189 GiB of disk-only Engram tables), e.g. "41-q2 · ~152 GiB (341 GiB on disk)".
    var label: String {
        switch self {
        case .q2: return "41-q2 · ~152 GiB (341 GiB on disk)"
        case .q4: return "41-q4 · ~294 GiB (483 GiB on disk)"
        }
    }
}

/// The resolved model+quant choice that replaces the old `(variant, flashQuant)` pair
/// throughout the app. V4 Pro is always pro-imatrix; each Flash generation has its own
/// quant picker.
enum QuantSelection: Equatable {
    case pro
    case flash(FlashQuant)
    case flash41(Flash41Quant)

    var variant: Variant {
        switch self {
        case .pro: return .pro
        case .flash: return .flash
        case .flash41: return .flash41
        }
    }
    var quant: Quant {
        switch self {
        case .pro: return .proImatrix
        case .flash(let q): return q.quant
        case .flash41(let q): return q.quant
        }
    }
}
