import Foundation

enum Variant: String, CaseIterable, Identifiable, Codable {
    case pro, flash, flash41  // flash = V4 Flash 0731 GA; flash41 = DeepSeek V4.1 Flash
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .pro: return "V4 Pro"
        case .flash: return "V4 Flash"
        case .flash41: return "V4.1 1017"
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
        case .flash41: return "kv-flash-41-1017"
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

/// One transport file of a quant's download, including standard GGUF shards.
struct QuantPart: Equatable {
    let filename: String
    let bytes: Int64
    /// Published SHA-256, verified after download (and before joining).
    let sha256: String?
}

enum Quant {
    case proImatrix, q4Imatrix, q2Imatrix, q2q4Imatrix, q41Q2, q41MXFP4

    /// Standard GGUF shards have their own headers and tensor-relative offsets;
    /// they must be assembled into a new GGUF rather than concatenated.
    enum AssemblyFormat {
        case singleFile, ggufShards
    }

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
        case .q41Q2, .q41MXFP4: return "antirez/deepseek-v4.1-flash-gguf"
        }
    }

    /// Immutable Hub revision for the 1017 artifacts and their verified manifest.
    /// Earlier V4/Pro artifacts retain their existing upstream download URLs.
    var downloadRevision: String {
        switch self {
        case .q41Q2, .q41MXFP4: return "9dcee51692e6540f697141fc98b097e3c96492a3"
        default: return "main"
        }
    }

    var assemblyFormat: AssemblyFormat { self == .q41MXFP4 ? .ggufShards : .singleFile }

    /// Network bytes include each shard's header and transport alignment, so they
    /// differ from the final page-aligned GGUF size for an assembled quant.
    var downloadBytes: Int64 { downloadParts.reduce(0) { $0 + $1.bytes } }

    /// The ds4 model-target identifier for this quant (e.g. `pro-q2-imatrix`).
    var arg: String {
        switch self {
        // ds4 renamed the single-file Pro target `pro-imatrix` → `pro-q2-imatrix`.
        case .proImatrix: return "pro-q2-imatrix"
        case .q4Imatrix: return "q4-imatrix"
        case .q2Imatrix: return "q2-imatrix"
        case .q2q4Imatrix: return "q2-q4-imatrix"
        case .q41Q2: return "ds41f-q2"
        case .q41MXFP4: return "ds41f-mxfp4"
        }
    }

    /// Exact GGUF filename the downloader fetches (under $DS4_GGUF_DIR / gguf) — the final,
    /// joined name where the download is split. Names are antirez's official GA builds:
    /// Pro 0813, Flash 0731, and V4.1 Flash 1017. The V4/Pro quant recipes and exact byte sizes
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
            return "DeepSeek-V4.1-Flash-1017-IQ2_XXS-Q2_K-imatrix.gguf"
        case .q41MXFP4:
            return "DeepSeek-V4.1-Flash-1017-MXFP4-experts.gguf"
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
        case .q41MXFP4: return 278
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
        case .q41MXFP4: return 501_609_136_128
        }
    }

    /// V4.1 only: bytes resident when the model is fully loaded. The GGUF carries
    /// 202,758,032,400 B (two tables: 384,006,168 + 384,016,682 rows × 264 B) of disk-only
    /// Engram rows. Subtracting their payload retains 13,296 B of alignment padding
    /// that pinned ds4 also unmaps, giving a conservative resident estimate.
    /// nil for V4/Pro (the whole file is resident).
    var residentMainBytes: Int? {
        switch self {
        case .q41Q2, .q41MXFP4: return ggufBytes - 202_758_032_400
        default: return nil
        }
    }

    /// Whole-file SHA-256 published by upstream, verified after download. nil where
    /// upstream publishes none (V4/Pro artifacts predate digest verification).
    var sha256: String? {
        switch self {
        case .q41Q2: return "5296e85ff64b42ecb62c8d0c0c54e1caa07e3df8e93112f2365ebbaed62ce93a"
        case .q41MXFP4: return "79608a69cd5bb919d8140c37105edc3a33419692d4e6caf4e68c901e4b359141"
        default: return nil
        }
    }

    /// Transport files to fetch, in order. V4.1 1017 MXFP4 ships as nine standard GGUF
    /// shards whose headers and tensor payloads must be reassembled after verification.
    var downloadParts: [QuantPart] {
        switch self {
        case .q41MXFP4:
            return [
                QuantPart(
                    filename: "DeepSeek-V4.1-Flash-1017-MXFP4-experts-00001-of-00009.gguf", bytes: 49_353_784_544,
                    sha256: "636918b09de6253bf41af29f06aac3ceeda220e46379d8a2058ef92c4e433ed8"),
                QuantPart(
                    filename: "DeepSeek-V4.1-Flash-1017-MXFP4-experts-00002-of-00009.gguf", bytes: 49_412_635_712,
                    sha256: "b26d3fc1e6ae1be6c52665542f3c1fee6a33791478f26e6cd90b5a75940a9f96"),
                QuantPart(
                    filename: "DeepSeek-V4.1-Flash-1017-MXFP4-experts-00003-of-00009.gguf", bytes: 49_582_960_352,
                    sha256: "20c7fe7adb0578336d8a5e5f9eed521aeb88e8c119ba46e0916cdaab28931c80"),
                QuantPart(
                    filename: "DeepSeek-V4.1-Flash-1017-MXFP4-experts-00004-of-00009.gguf", bytes: 49_418_206_432,
                    sha256: "67592ba15870c4292a615666adcc2736b53cc345b2cccb1c36710a0a6caf15b4"),
                QuantPart(
                    filename: "DeepSeek-V4.1-Flash-1017-MXFP4-experts-00005-of-00009.gguf", bytes: 49_412_829_632,
                    sha256: "ecd04e0aa71bfab8cfe79ea7fef7f35b6be0b6772455139e2081d6ce1dcc18ed"),
                QuantPart(
                    filename: "DeepSeek-V4.1-Flash-1017-MXFP4-experts-00006-of-00009.gguf", bytes: 49_257_603_776,
                    sha256: "88214e0cc80fbae578b80c114527e6ce725199684e0b6849475c7d00b3d0f54c"),
                QuantPart(
                    filename: "DeepSeek-V4.1-Flash-1017-MXFP4-experts-00007-of-00009.gguf", bytes: 2_406_482_112,
                    sha256: "38939faf3e4258f3ae333f0fa1954ce89515b75ceee90d37bf4ebe5fafe285e6"),
                QuantPart(
                    filename: "DeepSeek-V4.1-Flash-1017-MXFP4-experts-00008-of-00009.gguf", bytes: 101_377_628_544,
                    sha256: "a9d1634da2ac57459a64b10b69ddedfadda7dcde0e71ca6e55bea7c293c4a9f0"),
                QuantPart(
                    filename: "DeepSeek-V4.1-Flash-1017-MXFP4-experts-00009-of-00009.gguf", bytes: 101_380_404_256,
                    sha256: "b9832b355288c005da6ef444d02424464dd27f6ebdefeadbec2244264eb65285"),
            ]
        default:
            return [QuantPart(filename: ggufFilename, bytes: Int64(ggufBytes), sha256: sha256)]
        }
    }

    /// Pre-1017 V4.1 artifacts retained only for explicit migration cleanup.
    static let legacyFlash41Filenames = [
        "DeepSeek-V4.1-Flash-Q2.gguf",
        "DeepSeek-V4.1-Flash-Q4.gguf",
        "DeepSeek-V4.1-Flash-Q4.gguf.part1",
        "DeepSeek-V4.1-Flash-Q4.gguf.part2",
    ]

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
    case q2, mxfp4
    var id: String { rawValue }
    var quant: Quant {
        switch self {
        case .q2: return .q41Q2
        case .mxfp4: return .q41MXFP4
        }
    }
    /// Picker label: weights key + resident main weights + file size on disk (the file also
    /// carries ~189 GiB of disk-only Engram tables).
    var label: String {
        switch self {
        case .q2: return "1017-q2 · ~152 GiB (341 GiB on disk)"
        case .mxfp4: return "1017-mxfp4 · ~278 GiB (467 GiB on disk)"
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

    /// Checkpoints depend on quantized weights as well as model generation.
    var kvCacheDirectoryName: String {
        switch self {
        case .flash41(let q): return "\(variant.kvCacheDirectoryName)-\(q.rawValue)"
        case .pro, .flash: return variant.kvCacheDirectoryName
        }
    }
}
