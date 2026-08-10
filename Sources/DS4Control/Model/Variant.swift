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
    case proImatrix, q4Imatrix, q2Imatrix, q2q4Imatrix, q8Experts

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
        // No upstream download_model.sh target exists for this one — it's built locally by
        // gguf-tools. `arg` is vestigial anyway (the app uses the native downloader).
        case .q8Experts: return "q8"
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
        // Built locally from the 0731 safetensors with ds4's gguf-tools (`--experts q8_0`), using
        // the q4-imatrix GGUF as template so every non-expert tensor is carried over unchanged.
        //
        // q8_0, NOT q8_K: gguf-tools will happily emit q8_K experts (its README even documents a
        // "True Q8_K routed experts" recipe), but ds4's own loader rejects the result —
        // `tensor_is_routed_expert_type` accepts only Q8_0 / IQ2_XXS / Q2_K / Q4_K / Q5_K / Q6_K.
        // Q8_K in the engine is an *activation* format, not expert storage.
        //
        // No `-imatrix` in the name: the Q8_0 path discards the imatrix (quants.c
        // `(void)imatrix;`), as do the Q8_0/F16 tensors around it — nothing here is
        // imatrix-influenced. `Q8Experts` matches how the existing names spell q8_0 (Q8Attn,
        // Q8Shared, Q8Out).
        case .q8Experts:
            return
                "DeepSeek-V4-Flash-Q8Experts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-0731.gguf"
        }
    }

    /// Approx resident weights, GiB (mmap'd GGUF ≈ file size).
    var weightsGiB: Double {
        switch self {
        case .proImatrix: return 432
        case .q4Imatrix: return 153
        case .q2Imatrix: return 81
        case .q2q4Imatrix: return 91
        // 282.33 GiB — the built file is exactly 303,146,197,600 bytes, matching the quantizer's
        // dry-run plan to the byte.
        case .q8Experts: return 282.33
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
    /// Q8_0 routed experts, every other tensor as q4-imatrix. The released experts are FP4
    /// (`expert_dtype` in the model config), so this adds no information — it removes the second
    /// lossy step q4_K applies, making it the fidelity ceiling for the expert weights.
    ///
    /// **Prefer `.q4` for real use.** That second step is measurable at the weight level (5.34%
    /// relative RMSE, cosine 0.9984, flat across depth) but does NOT show up in output quality:
    /// scored against the 100 official Flash continuations, no metric reaches significance
    /// (avg_nll delta 95% CI crosses zero, case wins 52/48, first-token McNemar p=0.22). This
    /// variant is a reference control for measuring quantization damage, not a daily driver.
    ///
    /// Speed is not the objection — 30.96 vs 34.85 tok/s on an M3 Ultra, ~11%, because the MoE is
    /// sparse (6 of 256 experts per token). The cost is the 282 GiB footprint.
    case q8 = "q8"
    var id: String { rawValue }
    var quant: Quant {
        switch self {
        case .q2: return .q2Imatrix
        case .q2q4: return .q2q4Imatrix
        case .q4: return .q4Imatrix
        case .q8: return .q8Experts
        }
    }
    /// Picker label: weights generation + internal key + approximate resident size,
    /// e.g. "0731-q2-q4-imatrix · ~91 GiB". All Flash quants are the 0731 builds.
    var label: String { "0731-\(rawValue) · ~\(Int(quant.weightsGiB)) GiB" }
}
