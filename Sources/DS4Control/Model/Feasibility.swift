import Foundation
import Metal

enum Feasibility: Equatable {
    case standard
    /// The launch config's GPU-wired working set (weights + resident context allocations
    /// + shared graph/backend workspace) exceeds the machine's effective Metal wired limit.
    /// Starting anyway pages the model and hangs the machine, so Start is gated until
    /// the limit is raised (an explicit "Start anyway" override remains). `advisoryMB`
    /// is the sysctl value that makes this config fit.
    case wiredLimitTooLow(requiredMB: Int, advisoryMB: Int)
    case blocked(reason: String)  // cannot run on this machine
}

/// Physical unified memory in GiB.
func systemRamGiB() -> Double {
    var bytes: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &bytes, &size, nil, 0)
    return Double(bytes) / 1_073_741_824.0
}

/// Current `iogpu.wired_limit_mb` (MB). 0 = OS default (the user hasn't raised it).
/// Used to hide the wired-limit advisory once it's been set high enough.
func currentWiredLimitMB() -> Int {
    var value = 0  // zero-initialized: a 4-byte sysctl lands in the low bytes on arm64
    var size = MemoryLayout<Int>.size
    guard sysctlbyname("iogpu.wired_limit_mb", &value, &size, nil, 0) == 0 else { return 0 }
    return value
}

/// The OS's default GPU wired ceiling in MB, as advertised by Metal. This is NOT a
/// constant fraction of RAM (~75% on most Macs, ~84% on newer macOS), so it is queried,
/// never assumed. Cached: it only changes once `iogpu.wired_limit_mb` is set, and then
/// the live sysctl read wins anyway (see `effectiveWiredLimitMB`).
private let metalDefaultWiredLimitMB: Int = {
    guard let device = MTLCreateSystemDefaultDevice() else { return 0 }
    return Int(device.recommendedMaxWorkingSetSize / (1024 * 1024))
}()

/// The OS-default GPU wired ceiling for this machine (MB): Metal's advertised
/// `recommendedMaxWorkingSetSize`, falling back to a conservative 75% of RAM when Metal
/// can't report a device. Clamped to total RAM.
func defaultWiredLimitMB(ramGiB: Double) -> Int {
    let metal = metalDefaultWiredLimitMB
    guard metal > 0 else { return Int(ramGiB * 1024 * 0.75) }
    return min(metal, Int(ramGiB * 1024))
}

/// Test/debug override: when `DS4_EMULATE_WIRED_LIMIT_MB` is a positive integer, the
/// effective limit reports that instead of the machine's real one — so the gated-Start
/// notice can be exercised without touching the sysctl (no sudo needed).
func emulatedWiredLimitMB() -> Int? {
    #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["DS4_EMULATE_WIRED_LIMIT_MB"],
            let mb = Int(raw), mb > 0
        else { return nil }
        return mb
    #else
        return nil
    #endif
}

/// Effective GPU wired ceiling right now (MB): the user's `iogpu.wired_limit_mb` when
/// raised — read live, so running the sysctl in Terminal un-gates the popup within a
/// metrics tick — else the OS default.
func effectiveWiredLimitMB(ramGiB: Double) -> Int {
    if let emulated = emulatedWiredLimitMB() { return emulated }
    let set = currentWiredLimitMB()
    return set > 0 ? set : defaultWiredLimitMB(ramGiB: ramGiB)
}

/// Minimum context ds4 needs to engage Think Max (`DS4_THINK_MAX_MIN_CONTEXT`).
let thinkMaxMinCtx = 393_216
let thinkMaxMinRamGiB = 128.0

func thinkMax(ctx: Int) -> Bool { ctx >= thinkMaxMinCtx }
func supportsMaxThink(ramGiB: Double) -> Bool { ramGiB >= thinkMaxMinRamGiB }

/// Whether Max Think needs ds4's 393,216-token context floor. The floor is the DeepSeek4
/// family's `DS4_THINK_MAX_MIN_CONTEXT` (Pro/Flash 0731); V4.1 uses numeric reasoning
/// effort (1-100, max = 100) with no context gate.
func thinkMaxNeedsCtxFloor(variant: Variant) -> Bool { variant != .flash41 }

/// Headroom left for macOS and other processes — also the buffer the Metal
/// wired-limit advisory leaves below total RAM.
let osReserveGiB = 4.0
let maxConcurrentSessions = 16

/// Suggested `iogpu.wired_limit_mb`: total RAM minus the OS reserve, so the GPU-wired
/// working set (weights + resident context allocations + graph/backend allocations) fits.
/// A percentage heuristic under-shoots the largest models. The 4 GiB reserve is
/// intentional: the real-model harness measured Flash q2 weights at ~80.8 GiB and
/// confirmed context memory is additive; pinned ds4 sizing plus a conservative bound
/// for its persistent indexer scratch puts the 256,000-token default at 93,390 MiB,
/// below the 94,208 MiB ceiling on a 96 GiB Mac.
func wiredLimitAdvisoryMB(ramGiB: Double) -> Int { Int((ramGiB - osReserveGiB) * 1024) }

private let bytesPerMiB = 1024 * 1024

private struct MetalShape {
    let ratio4Layers: Int
    let ratio128Layers: Int
    let longPromptPrefillCap: Int
    let embeddingWidth: Int
    let attentionHeads: Int
    let headWidth: Int
    let outputGroups: Int
    let queryRank: Int
    let outputRank: Int
    let expertCount: Int
    let expertsUsed: Int
    let expertWidth: Int
    let indexerHeads: Int
    let indexerHeadWidth: Int
    let indexerTopK: Int
    let hyperConnections: Int
    let vocabularySize: Int
}

private func metalShape(for variant: Variant) -> MetalShape {
    switch variant {
    case .flash:
        return MetalShape(
            ratio4Layers: 21, ratio128Layers: 20, longPromptPrefillCap: 4096,
            embeddingWidth: 4096, attentionHeads: 64, headWidth: 512,
            outputGroups: 8, queryRank: 1024, outputRank: 1024,
            expertCount: 256, expertsUsed: 6, expertWidth: 2048,
            indexerHeads: 64, indexerHeadWidth: 128, indexerTopK: 512,
            hyperConnections: 4, vocabularySize: 129_280)
    case .pro:
        return MetalShape(
            ratio4Layers: 30, ratio128Layers: 31, longPromptPrefillCap: 8192,
            embeddingWidth: 7168, attentionHeads: 128, headWidth: 512,
            outputGroups: 16, queryRank: 1536, outputRank: 1024,
            expertCount: 384, expertsUsed: 6, expertWidth: 3072,
            indexerHeads: 64, indexerHeadWidth: 128, indexerTopK: 1024,
            hyperConnections: 4, vocabularySize: 129_280)
    case .flash41:
        preconditionFailure("V4.1 Flash uses ds41GraphBytes; metalShape is DeepSeek V4-only")
    }
}

private func metalPrefillCap(shape: MetalShape, ctx: Int) -> Int {
    ctx > 4096 ? min(shape.longPromptPrefillCap, ctx) : ctx
}

private func checkedProduct(_ values: [Int]) -> Int? {
    var result = 1
    for value in values {
        let (next, overflow) = result.multipliedReportingOverflow(by: value)
        guard !overflow else { return nil }
        result = next
    }
    return result
}

private func checkedSum(_ values: [Int]) -> Int? {
    var result = 0
    for value in values {
        let (next, overflow) = result.addingReportingOverflow(value)
        guard !overflow else { return nil }
        result = next
    }
    return result
}

private func roundedUpMiB(_ bytes: Int) -> Int? {
    guard bytes >= 0 else { return nil }
    let (result, overflow) = (bytes / bytesPerMiB).addingReportingOverflow(
        bytes % bytesPerMiB == 0 ? 0 : 1)
    return overflow ? nil : result
}

func roundedUpGiB(fromMB megabytes: Int) -> Int {
    guard megabytes > 0 else { return 0 }
    return megabytes / 1024 + (megabytes % 1024 == 0 ? 0 : 1)
}

/// Mirrors pinned ds4's Metal `ds4_context_memory_estimate_with_prefill_mode` for
/// DeepSeek V4. This includes raw KV, per-layer compressed caches, and the
/// context-dependent prefill scratch that each resident session allocates.
private func metalContextBytes(variant: Variant, ctx: Int) -> Int? {
    guard ctx >= 0 else { return nil }
    guard ctx > 0 else { return 0 }

    let shape = metalShape(for: variant)
    let prefillCap = metalPrefillCap(shape: shape, ctx: ctx)
    let rawWindow = min(128, ctx)
    guard let wanted = checkedSum([rawWindow, prefillCap]) else { return nil }
    let cappedWanted = min(wanted, ctx)
    let (alignmentInput, alignmentOverflow) = cappedWanted.addingReportingOverflow(255)
    guard !alignmentOverflow else { return nil }
    let rawCap = max(rawWindow, min((alignmentInput / 256) * 256, 8192))

    guard
        let ratio4Cap = checkedSum([ctx / 4, 2]),
        let ratio128Cap = checkedSum([ctx / 128, 2]),
        let rawBytes = checkedProduct([variant.layers, rawCap, 512, 4]),
        let ratio4AttentionBytes = checkedProduct([ratio4Cap, 512, 2]),
        let ratio4IndexerBytes = checkedProduct([ratio4Cap, 128, 4]),
        let ratio4LayerBytes = checkedSum([ratio4AttentionBytes, ratio4IndexerBytes]),
        let ratio4Bytes = checkedProduct([shape.ratio4Layers, ratio4LayerBytes]),
        let ratio128LayerBytes = checkedProduct([ratio128Cap, 512, 2]),
        let ratio128Bytes = checkedProduct([shape.ratio128Layers, ratio128LayerBytes]),
        let scratchMatricesBytes = checkedProduct([2, ratio4Cap, prefillCap, 4]),
        let attentionStageCap = checkedSum([prefillCap / 4, 2]),
        let attentionStageBytes = checkedProduct([attentionStageCap, 512, 4])
    else { return nil }

    return checkedSum([
        rawBytes, ratio4Bytes, ratio128Bytes, scratchMatricesBytes, attentionStageBytes,
    ])
}

/// Mirrors pinned ds4's long-lived Metal prefill workspace. `ds4-server` shares one
/// workspace across batched sessions; a single-session server owns one equivalent set.
/// Include the lazily materialized `batch_ffn_out` buffer because the wired-limit gate
/// must cover peak prefill, not only the allocation state immediately after launch.
private func metalSharedGraphWorkspaceBytes(variant: Variant, ctx: Int) -> Int? {
    guard ctx >= 0 else { return nil }
    guard ctx > 0 else { return 0 }

    let shape = metalShape(for: variant)
    let prefillCap = metalPrefillCap(shape: shape, ctx: ctx)
    guard
        let hyperConnectionWidth = checkedProduct([shape.hyperConnections, shape.embeddingWidth]),
        let hyperConnectionMixWidth = checkedSum([
            2 * shape.hyperConnections, shape.hyperConnections * shape.hyperConnections,
        ]),
        let queryWidth = checkedProduct([shape.attentionHeads, shape.headWidth]),
        let groupedOutputWidth = checkedProduct([shape.outputGroups, shape.outputRank]),
        let groupTemporaryWidth = checkedProduct([
            shape.headWidth, shape.attentionHeads / shape.outputGroups,
        ]),
        let indexerQueryWidth = checkedProduct([shape.indexerHeads, shape.indexerHeadWidth]),
        let compressionWidth = checkedProduct([2, max(shape.headWidth, shape.indexerHeadWidth)]),
        let floatElementsPerToken = checkedSum([
            1,  // prefill_tokens (int32)
            8 * shape.embeddingWidth,
            shape.expertsUsed * shape.embeddingWidth,
            3 * shape.expertsUsed * shape.expertWidth,
            2 * shape.expertsUsed,
            2 * shape.expertCount,
            3 * shape.expertWidth,
            4 * hyperConnectionWidth,
            shape.outputRank,
            groupTemporaryWidth,
            groupedOutputWidth,
            2 * queryWidth,
            shape.indexerHeads,
            indexerQueryWidth,
            2 * compressionWidth,
            2 * shape.headWidth,
            2 * shape.queryRank,
            2 * hyperConnectionMixWidth,
        ]),
        let floatBytes = checkedProduct([prefillCap, floatElementsPerToken, 4]),
        let halfQueryBytes = checkedProduct([prefillCap, queryWidth, 2]),
        let seedBytes = checkedProduct([variant.layers, 64, shape.expertsUsed, 4])
    else { return nil }

    return checkedSum([floatBytes, halfQueryBytes, seedBytes])
}

/// Per-session graph allocations omitted by ds4's public context estimator. The large
/// score/mask and attention-stage tensors are already in `metalContextBytes`, so this
/// adds only the remaining decode/head buffers and fixed per-layer compressor state.
private func metalSessionGraphBytes(variant: Variant, ctx: Int) -> Int? {
    guard ctx >= 0 else { return nil }
    guard ctx > 0 else { return 0 }

    let shape = metalShape(for: variant)
    let prefillCap = metalPrefillCap(shape: shape, ctx: ctx)
    guard
        let hyperConnectionWidth = checkedProduct([shape.hyperConnections, shape.embeddingWidth]),
        let hyperConnectionMixWidth = checkedSum([
            2 * shape.hyperConnections, shape.hyperConnections * shape.hyperConnections,
        ]),
        let queryWidth = checkedProduct([shape.attentionHeads, shape.headWidth]),
        let groupedOutputWidth = checkedProduct([shape.outputGroups, shape.outputRank]),
        let indexerQueryWidth = checkedProduct([shape.indexerHeads, shape.indexerHeadWidth]),
        let compressionWidth = checkedProduct([2, max(shape.headWidth, shape.indexerHeadWidth)]),
        let selectedIndexElements = checkedProduct([shape.indexerTopK, prefillCap]),
        let decodeElements = checkedSum([
            2 * hyperConnectionWidth,
            2 * hyperConnectionMixWidth,
            2 * shape.embeddingWidth,
            2 * shape.queryRank,
            queryWidth,
            2 * shape.headWidth,
            2 * compressionWidth,
            4 * shape.indexerHeadWidth,
            indexerQueryWidth,
            shape.indexerHeads,
            selectedIndexElements,
            queryWidth,
            groupedOutputWidth,
            shape.embeddingWidth,
            hyperConnectionWidth,
            2 * shape.embeddingWidth,
            3 * shape.expertWidth,
            shape.embeddingWidth,
            2 * shape.expertCount,
            2 * shape.expertsUsed,
            3 * shape.expertsUsed * shape.expertWidth,
            shape.expertsUsed * shape.embeddingWidth,
            shape.embeddingWidth,
            hyperConnectionWidth,
            2 * shape.hyperConnections,
            2 * shape.embeddingWidth,
            shape.vocabularySize,
        ]),
        let ratio4StateElements = checkedProduct([
            shape.ratio4Layers, 32, shape.headWidth + shape.indexerHeadWidth,
        ]),
        let ratio128StateElements = checkedProduct([
            shape.ratio128Layers, 256, shape.headWidth,
        ]),
        let stateElements = checkedSum([ratio4StateElements, ratio128StateElements]),
        let totalElements = checkedSum([decodeElements, stateElements])
    else { return nil }

    return checkedProduct([totalElements, 4])
}

/// Server-wide scratch retained by ds4's Metal indexer after a long prefill reaches the
/// configured context frontier. The top-k selection allocation depends on the compute
/// pipeline's threadgroup limit; two banks of `nComp * nTokens` UInt32s are an upper bound
/// for every limit. Indexed attention simultaneously retains a second, sorted top-k buffer.
private func metalIndexerScratchBytes(variant: Variant, ctx: Int) -> Int? {
    guard ctx >= 0, ctx <= variant.ctxCeiling else { return nil }
    guard ctx > 0 else { return 0 }

    let shape = metalShape(for: variant)
    let prefillCap = metalPrefillCap(shape: shape, ctx: ctx)
    guard prefillCap > 0 else { return nil }

    func upperBounds(endPosition: Int, tokens: Int) -> (selection: Int, sorted: Int)? {
        let compressedRows = endPosition / 4
        guard compressedRows > shape.indexerTopK else { return (0, 0) }
        guard
            let selection = checkedProduct([
                2, compressedRows, tokens, MemoryLayout<UInt32>.size,
            ]),
            let sorted = checkedProduct([
                shape.indexerTopK, tokens, MemoryLayout<UInt32>.size,
            ])
        else { return nil }
        return (selection, sorted)
    }

    let partialTokens = ctx % prefillCap
    let lastFullEnd = ctx - partialTokens
    guard
        let fullChunk = lastFullEnd > 0
            ? upperBounds(endPosition: lastFullEnd, tokens: prefillCap) : (0, 0),
        let partialChunk = partialTokens > 0
            ? upperBounds(endPosition: ctx, tokens: partialTokens) : (0, 0)
    else { return nil }
    return checkedSum([
        max(fullChunk.selection, partialChunk.selection),
        max(fullChunk.sorted, partialChunk.sorted),
    ])
}

// MARK: - DeepSeek V4.1 Flash (ds41) Metal memory mirror
//
// The V4.1 graphite and admission rules live in ds4@bd66c40 (see AGENTS.md). Constants
// below are transcribed from that revision; do not carry them across a ds4 bump without
// re-verifying `ds41_graph_bytes`, `ds41_carry_cap` and `ds4_streaming_prefill_headroom_bytes`.

/// V4.1 Flash shape (`DS4_SHAPE_FLASH41`, ds4.c:604-639).
private enum DS41Shape {
    static let layers = 40
    static let embd = 5120
    static let vocab = 129_280
    static let head = 64
    static let headDim = 512
    static let outGroup = 8
    static let loraQ = 1280
    static let loraO = 1024
    static let expert = 384
    static let expertUsed = 6
    static let ffExp = 2304
    static let indexerHead = 32
    static let indexerHeadDim = 128
    static let indexerTopK = 512
    static let hc = 4
    static let engramCols = 24
    static let engramDim = 256
}

/// `sizeof(ds41_gpu_graph)` at bd66c40 (clang record layout; pointers + scalars only).
private let ds41GraphStructBytes = 51_080
/// `DS41_PREFILL_CAP` and index batch width (ds4.c:39058-39059).
private let ds41PrefillCapWide = 8192
private let ds41IndexBatch = 32

/// `ds41_prefill_limit` (ds4.c:39100): wide chunks need enough context.
private func ds41PrefillCap(ctx: Int) -> Int {
    if ctx < 8192 { return min(2048, ctx) }
    if ctx < 16384 { return min(4096, ctx) }
    return min(ds41PrefillCapWide, ctx)
}

/// `ds41_carry_words` for the default compact (non-F32) formats.
private func ds41CarryWords(width: Int, mask: Bool) -> Int {
    mask ? (width + 31) / 32 : (width + 1) / 2
}

/// `ds41_carry_cap` (ds4.c:39111): the 3 GiB carry budget in rows, bounded and aligned.
private func ds41CarryCap(ctx: Int) -> Int {
    let blockMask = (ctx + 7) / 8
    let rowBytes =
        (ds41CarryWords(width: DS41Shape.hc * DS41Shape.embd, mask: false)
            + DS41Shape.hc + 24 + DS41Shape.indexerTopK
            + ds41CarryWords(width: blockMask, mask: true)) * 4
    guard rowBytes > 0 else { return 0 }
    var cap = (3 << 30) / rowBytes
    if cap > 32768 { cap = 32768 }
    if cap > ctx { cap = ctx }
    let chunk = ds41PrefillCap(ctx: ctx)
    guard chunk > 0 else { return 0 }
    cap -= cap % 2048
    return cap > chunk ? cap : 0
}

/// `ds4_gpu_dsv41_indexer_packed_bytes` (ds4_metal.m:36065).
private func ds41IndexerPackedBytes(sourceRows: Int, rows: Int) -> Int {
    let flags = ((rows + (sourceRows + 63) / 64) * 4 + 255) & ~255
    return flags + rows * 32 * 128 * 2 + ((sourceRows + 63) / 64) * 64 * 128 * 2
}

/// Exact bytes of one resident session's V4.1 Metal graph, mirroring `ds41_graph_bytes`
/// (ds4.c:39227). All terms are bounded by `ctx <= 1,048,576`, so Int cannot overflow
/// (~21 GiB max). `sizeof(*g)`, the token map, the bounded packed activation buffer and
/// the index-sorter merge buffers are included exactly as ds4 accounts them.
func ds41GraphBytes(ctx: Int) -> Int? {
    guard ctx > 0, ctx <= 1_048_576 else { return nil }
    let shape = DS41Shape.self
    let prefillCap = ds41PrefillCap(ctx: ctx)
    let carryCap = ds41CarryCap(ctx: ctx)
    let blockMask = (ctx + 7) / 8

    var floats = 40 * 128 * 512
    for i in 0..<4 {
        floats += (ctx / (i < 3 ? 2 : 1) + 1) * (512 + 128) + 2 * 512
    }
    floats += 2 * 2 * shape.embd * shape.hc
    // DS41_SCRATCH (ds4.c:39126).
    floats += (prefillCap + 3) / 4  // image_text_mask
    floats += 3 * shape.hc * shape.embd  // residual, after_attn, flat_norm
    floats += 24 + 24 + 24 + 4  // mix, attn_split, ffn_split, pre
    floats += 3 * shape.embd  // x, norm, block
    floats += shape.loraQ + shape.head * shape.headDim + 2 * shape.headDim  // qr, q, kv+latent
    floats += (prefillCap + 128) * shape.headDim  // raw_prefill
    floats += 2 * shape.headDim  // pool_kv, pool_score
    floats += shape.indexerHead * shape.indexerHeadDim + shape.indexerHeadDim + shape.indexerHead
    floats += ds41IndexBatch * ctx  // index_scores
    floats += shape.indexerTopK  // selected_comp
    floats += ds41IndexerPackedBytes(sourceRows: ctx, rows: prefillCap) / 4  // index_packed
    floats += shape.indexerTopK * shape.headDim  // selected_kv
    floats += blockMask  // block_scores
    floats += 2048  // block_selected
    floats += blockMask  // block_mask
    floats += shape.head * shape.headDim + shape.outGroup * shape.loraO  // heads, low
    floats += 2 * shape.expert  // route_logits, route_probs
    floats += 2 * shape.expertUsed  // selected, route_weights
    floats += 3 * shape.expertUsed * shape.ffExp  // gate, up, mid
    floats += shape.expertUsed * shape.embd + shape.embd  // experts, routed
    floats += 3 * shape.ffExp + shape.embd  // shared_gate, shared_up, shared_mid, shared
    floats += shape.engramCols * shape.engramDim  // engram_rows
    floats += (carryCap > 0 ? carryCap : prefillCap) * shape.engramCols * shape.engramDim
    floats += (shape.hc + 1) * shape.embd  // engram_kv
    floats += shape.vocab  // logits
    // DS41_PREFILL_STORAGE * prefill_cap; the aliases stay uncounted because ds4 enables
    // the default aliasing (DS4_METAL_DISABLE_V41_PREFILL_ALIAS is unset).
    let prefillStorage =
        shape.hc * shape.embd  // residual
        + shape.hc  // pre
        + shape.indexerTopK  // selected_comp
        + shape.expertUsed  // selected
        + shape.hc * shape.embd  // after_attn
        + 24 + 24  // ffn_split, attn_split
        + shape.loraQ  // qr
        + shape.head * shape.headDim  // q
        + shape.headDim + shape.headDim  // kv, latent
        + shape.indexerHeadDim  // index_k
        + shape.headDim + shape.headDim  // pool_kv, pool_score
        + shape.indexerHead * shape.indexerHeadDim  // index_q
        + shape.indexerHead  // index_weights
        + shape.head * shape.headDim  // heads
        + shape.outGroup * shape.loraO  // low
        + shape.embd  // block
        + 24  // mix
        + shape.embd + shape.embd  // x, norm
        + shape.expert + shape.expert  // route_logits, route_probs
        + shape.expertUsed  // route_weights
        + shape.expertUsed * shape.ffExp  // mid
        + blockMask  // block_mask
        + shape.engramCols * shape.engramDim  // engram_rows
    floats += prefillStorage * prefillCap
    // DS41_CARRY_ROWS * carry_cap.
    floats += ds41CarryWords(width: shape.hc * shape.embd, mask: false) * carryCap
    floats += shape.hc * carryCap
    floats += 24 * carryCap
    floats += shape.indexerTopK * carryCap
    floats += ds41CarryWords(width: blockMask, mask: true) * carryCap
    floats += prefillCap * 512  // row-view objects
    if carryCap > prefillCap {
        floats += (carryCap - prefillCap) * 2 * shape.engramCols  // host hash-ID array
    }
    let packed = prefillCap >= 512 ? (prefillCap > 4096 ? 512 : 256) * 1024 * 1024 : 0
    let sort = ds41IndexBatch * ctx * 2 * 4  // index-sorter merge buffers
    return floats * 4 + ds41GraphStructBytes + shape.vocab * 4 + packed + sort
}

/// Fixed wired bytes for V4.1 before the auto-fitted expert cache, from the quantize plan
/// (`deepseek41_quantize.py`) plus `weights_model_map_decode_static_spans` (ds4.c:7577):
/// every non-routed decode-static tensor (token table, output head, attention/compressor/
/// indexer/shared-expert/HC tensors and the two engram KV projections). Identical for Q2
/// and Q4 because only routed experts change precision between the recipes.
let ds41NonRoutedBytes = 10_061_367_744

/// `ds4_streaming_prefill_headroom_bytes` (ds4.c:4878) for V4.1: one routed layer's
/// experts × `DS4_STREAMING_PREFILL_HEADROOM_LAYERS` (2), per recipe.
let ds41Q2PrefillHeadroomBytes = 7_644_119_040
let ds41Q4PrefillHeadroomBytes = 15_288_238_080

/// V4.1 fixed working set (MB) before the expert cache, mirroring the `fixed` term of
/// `ds41_memory_admit_for_host` (ds4.c:65460): resident or streamed weights + one graph
/// per resident session + ds4's fixed 2 GiB (+ the streaming prefill headroom).
func v41FixedWiredMB(quant: Quant, ctx: Int, sessions: Int, streaming: Bool) -> Int {
    guard let resident = quant.residentMainBytes, let graph = ds41GraphBytes(ctx: ctx) else {
        return Int.max
    }
    let weights = streaming ? ds41NonRoutedBytes : resident
    let headroom =
        streaming
        ? (quant == .q41Q4 ? ds41Q4PrefillHeadroomBytes : ds41Q2PrefillHeadroomBytes) : 0
    let (graphSessions, graphOverflow) = graph.multipliedReportingOverflow(by: max(sessions, 1))
    guard !graphOverflow else { return Int.max }
    let (fixed, overflow) = weights.addingReportingOverflow(
        graphSessions + 2 * 1024 * 1024 * 1024 + headroom)
    guard !overflow, let mb = roundedUpMiB(fixed) else { return Int.max }
    return mb
}

/// ds4's V4.1 admission budget: `min(host × 7/8, recommended working set)` (ds4.c:65468).
func flash41BudgetMB(ramGiB: Double, wiredLimitMB: Int) -> Int {
    min(Int(ramGiB * 1024 * 7 / 8), wiredLimitMB)
}

/// Auto `--ssd-streaming`: engage when the fully resident fixed set exceeds ds4's admission
/// budget. `wiredLimitMB` is the machine's effective Metal ceiling (inject at call sites,
/// as with `feasibility`).
func flash41UsesSSDStreaming(
    ramGiB: Double, wiredLimitMB: Int, quant: Quant, ctx: Int, sessions: Int
) -> Bool {
    let resident = v41FixedWiredMB(quant: quant, ctx: ctx, sessions: sessions, streaming: false)
    guard resident != Int.max else { return true }
    return resident > flash41BudgetMB(ramGiB: ramGiB, wiredLimitMB: wiredLimitMB)
}

/// Documented RAM floor per V4.1 quant (README tier table): 41-q2 runs from 128 GiB via SSD
/// streaming; 41-q4 requires ≥ 256 GiB — the 128 GiB class would have to stream essentially
/// every routed expert, which the supported tiers do not offer.
func flash41MinRamGiB(_ q: Flash41Quant) -> Double { q == .q4 ? 256 : 128 }

/// Whether a V4.1 quant's default launch fits this machine. Drives which options the
/// Settings quant picker offers; the RAM floor is the documented tier, then the launch's
/// exact working set is checked against the wired-limit advisory.
func flash41QuantFits(_ q: Flash41Quant, ramGiB: Double, wiredLimitMB: Int) -> Bool {
    guard ramGiB >= flash41MinRamGiB(q) else { return false }
    let ctx = defaultCtx(ramGiB: ramGiB, selection: .flash41(q))
    let streaming = flash41UsesSSDStreaming(
        ramGiB: ramGiB, wiredLimitMB: wiredLimitMB, quant: q.quant, ctx: ctx, sessions: 1)
    let required = v41FixedWiredMB(
        quant: q.quant, ctx: ctx, sessions: 1, streaming: streaming)
    return required <= wiredLimitAdvisoryMB(ramGiB: ramGiB)
}

/// The GPU-wired working set ds4 needs for this launch config (MB): exact resident
/// GGUF bytes, ds4's Metal context and graph allocations for every resident session, and
/// one prefill workspace plus persistent backend scratch shared across sessions. Context
/// counts regardless of the disk KV cache: disk storage checkpoints resident tensors; it
/// does not replace them.
///
/// DeepSeek V4 path (Pro/Flash 0731), preserved for the V4 quantizers and pinned tests.
func requiredWiredMB(variant: Variant, flashQuant: FlashQuant, ctx: Int, sessions: Int = 1) -> Int {
    let quant = variant == .pro ? Quant.proImatrix : flashQuant.quant
    guard
        let weightsMB = roundedUpMiB(quant.ggufBytes),
        let sessionBytes = metalContextBytes(variant: variant, ctx: ctx),
        let sessionGraphBytes = metalSessionGraphBytes(variant: variant, ctx: ctx),
        let sharedGraphBytes = metalSharedGraphWorkspaceBytes(variant: variant, ctx: ctx),
        let indexerScratchBytes = metalIndexerScratchBytes(variant: variant, ctx: ctx),
        let perSessionBytes = checkedSum([sessionBytes, sessionGraphBytes])
    else { return Int.max }
    let (residentSessionBytes, sessionOverflow) = perSessionBytes.multipliedReportingOverflow(
        by: max(sessions, 1))
    guard
        !sessionOverflow,
        let allocationBytes = checkedSum([
            residentSessionBytes, sharedGraphBytes, indexerScratchBytes,
        ]),
        let allocationMB = roundedUpMiB(allocationBytes)
    else { return Int.max }
    let (requiredMB, totalOverflow) = weightsMB.addingReportingOverflow(allocationMB)
    return totalOverflow ? Int.max : requiredMB
}

/// Selection-based entry point. V4.1 Flash consults RAM and the wired ceiling for its
/// auto SSD-streaming decision; Pro and 0731 delegate to the V4 math above.
func requiredWiredMB(
    ramGiB: Double, wiredLimitMB: Int, selection: QuantSelection, ctx: Int, sessions: Int = 1
) -> Int {
    switch selection {
    case .pro:
        return requiredWiredMB(variant: .pro, flashQuant: .q2, ctx: ctx, sessions: sessions)
    case .flash(let q):
        return requiredWiredMB(variant: .flash, flashQuant: q, ctx: ctx, sessions: sessions)
    case .flash41(let q):
        let streaming = flash41UsesSSDStreaming(
            ramGiB: ramGiB, wiredLimitMB: wiredLimitMB, quant: q.quant, ctx: ctx,
            sessions: sessions)
        return v41FixedWiredMB(
            quant: q.quant, ctx: ctx, sessions: sessions, streaming: streaming)
    }
}

func launchBoundsError(variant: Variant, ctx: Int, sessions: Int) -> String? {
    guard (1...variant.ctxCeiling).contains(ctx) else {
        return "Context size must be between 1 and \(variant.ctxCeiling.formatted()) tokens."
    }
    guard (1...maxConcurrentSessions).contains(sessions) else {
        return "Concurrent sessions must be between 1 and \(maxConcurrentSessions)."
    }
    return nil
}

/// Default context, tiered by machine memory: V4 Pro and ≥128 GiB Flash (q2-q4 quant)
/// run the full 1M window all-resident; 96–127 GiB Flash (q2) is capped at 256K so its
/// complete Metal working set fits while preserving the macOS reserve. `flashQuant` is
/// accepted for API symmetry; the tier keys on RAM.
func defaultCtx(ramGiB: Double, variant: Variant, flashQuant: FlashQuant) -> Int {
    if variant == .pro { return variant.ctxCeiling }  // Pro: full 1M
    return ramGiB >= 128 ? variant.ctxCeiling : 256_000  // Flash: 1M on ≥128 GiB, else 256K
}

/// Whether a Flash quant's default launch fits while preserving the OS reserve.
/// Drives which options the Settings quant picker offers.
func flashQuantFits(_ q: FlashQuant, ramGiB: Double) -> Bool {
    let ctx = defaultCtx(ramGiB: ramGiB, variant: .flash, flashQuant: q)
    return requiredWiredMB(variant: .flash, flashQuant: q, ctx: ctx)
        <= wiredLimitAdvisoryMB(ramGiB: ramGiB)
}

/// Default Flash quant: q2-q4 on ≥128 GiB (room for the 1M window all-resident), else q2
/// (96–127 GiB). Only used when nothing is persisted yet.
func defaultFlashQuant(ramGiB: Double) -> FlashQuant {
    ramGiB >= 128 ? .q2q4 : .q2
}

/// Default V4.1 Flash quant: q4 on ≥512 GiB (full residency), else q2. Only used when
/// nothing is persisted yet.
func defaultFlash41Quant(ramGiB: Double) -> Flash41Quant {
    ramGiB >= 512 ? .q4 : .q2
}

/// Default context, tiered by model generation and machine memory. V4 Pro and ≥128 GiB
/// Flash (q2-q4 quant) run the full 1M window all-resident; 96–127 GiB Flash (q2) is
/// capped at 256K. V4.1 Flash defaults to the 1,048,576 ceiling when the machine holds that
/// window fully resident (the auto `--ssd-streaming` heuristic says no streaming is needed
/// at this RAM tier — 41-q2 from 256 GiB, 41-q4 from 384 GiB), else to upstream's documented
/// 32,768 SSD-streaming configuration (docs/MODELS.md@bd66c40); both are adjustable from
/// Settings.
func defaultCtx(ramGiB: Double, selection: QuantSelection) -> Int {
    switch selection {
    case .pro: return Variant.pro.ctxCeiling
    case .flash: return ramGiB >= 128 ? Variant.flash.ctxCeiling : 256_000
    case .flash41(let q):
        guard ramGiB >= flash41MinRamGiB(q) else { return 32_768 }
        let ceiling = Variant.flash41.ctxCeiling
        let streaming = flash41UsesSSDStreaming(
            ramGiB: ramGiB, wiredLimitMB: wiredLimitAdvisoryMB(ramGiB: ramGiB),
            quant: q.quant, ctx: ceiling, sessions: 1)
        return streaming ? 32_768 : ceiling
    }
}

/// Feasibility gate (spec §5.2). ds4 itself enforces no floor, so the app does. The RAM
/// tiers block outright; the Metal wired-limit check then gates the launch config's
/// exact weights-plus-context-plus-graph/backend working set against the machine's effective
/// ceiling (`wiredLimitMB` — inject `effectiveWiredLimitMB(ramGiB:)` at the call site).
func feasibility(
    ramGiB: Double, selection: QuantSelection,
    ctx: Int, wiredLimitMB: Int, sessions: Int = 1
) -> Feasibility {
    let variant = selection.variant
    if let reason = launchBoundsError(variant: variant, ctx: ctx, sessions: sessions) {
        return .blocked(reason: reason)
    }
    switch variant {
    case .pro:
        guard ramGiB >= 512 else { return .blocked(reason: "V4 Pro needs ≥ 512 GiB unified memory.") }
    case .flash:
        if ramGiB < 96 {
            return .blocked(
                reason:
                    "V4 Flash needs ≥ 96 GiB unified memory. Below that, its weights, resident context, and Metal graph allocations cannot fit safely."
            )
        }
    case .flash41:
        if case let .flash41(q) = selection, ramGiB < flash41MinRamGiB(q) {
            return .blocked(
                reason: q == .q4
                    ? "V4.1 Flash 41-q4 needs ≥ 256 GiB unified memory. Its 294 GiB of main weights would stream essentially every routed expert below that tier, which is not supported."
                    : "V4.1 Flash needs ≥ 128 GiB unified memory. Its 152 GiB of resident main weights, plus disk-only Engram streaming, cannot run safely below that."
            )
        }
    }
    let required = requiredWiredMB(
        ramGiB: ramGiB, wiredLimitMB: wiredLimitMB, selection: selection, ctx: ctx,
        sessions: sessions)
    if required == Int.max {
        return .blocked(
            reason:
                "This context and session count is too large to run on any Mac. Reduce context or concurrent sessions."
        )
    }
    let usableMB = wiredLimitAdvisoryMB(ramGiB: ramGiB)
    if required > usableMB {
        return .blocked(
            reason:
                "This setup needs ~\(roundedUpGiB(fromMB: required)) GiB unified memory, but this Mac has ~\(Int(ramGiB)) GiB and macOS needs ~\(Int(osReserveGiB)) GiB. Reduce context or concurrent sessions."
        )
    }
    if wiredLimitMB < required {
        return .wiredLimitTooLow(requiredMB: required, advisoryMB: usableMB)
    }
    return .standard
}

/// Compatibility shim for the DeepSeek V4 quantizers and their pinned tests.
func feasibility(
    ramGiB: Double, variant: Variant, flashQuant: FlashQuant,
    ctx: Int, wiredLimitMB: Int, sessions: Int = 1
) -> Feasibility {
    feasibility(
        ramGiB: ramGiB, selection: variant == .pro ? .pro : .flash(flashQuant),
        ctx: ctx, wiredLimitMB: wiredLimitMB, sessions: sessions)
}

/// Largest resident-session count whose launch config passes the wired-limit gate at the
/// live limit without the "Start anyway" override, capped at `maxConcurrentSessions`.
/// Always at least 1 — a config that needs the override (or is blocked outright) is
/// reported by the Start/Restart gate itself.
func maxFittingSessions(
    ramGiB: Double, selection: QuantSelection, ctx: Int, wiredLimitMB: Int
) -> Int {
    for sessions in stride(from: maxConcurrentSessions, through: 1, by: -1) {
        if case .standard = feasibility(
            ramGiB: ramGiB, selection: selection, ctx: ctx, wiredLimitMB: wiredLimitMB,
            sessions: sessions)
        {
            return sessions
        }
    }
    return 1
}
