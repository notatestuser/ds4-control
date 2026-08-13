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

/// The GPU-wired working set ds4 needs for this launch config (MB): exact resident
/// GGUF bytes, ds4's Metal context and graph allocations for every resident session, and
/// one prefill workspace plus persistent backend scratch shared across sessions. Context
/// counts regardless of the disk KV cache: disk storage checkpoints resident tensors; it
/// does not replace them.
func requiredWiredMB(variant: Variant, flashQuant: FlashQuant, ctx: Int, sessions: Int = 1) -> Int {
    let quant = Quant.for(variant, flashQuant: flashQuant)
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

/// Feasibility gate (spec §5.2). ds4 itself enforces no floor, so the app does. The RAM
/// tiers block outright; the Metal wired-limit check then gates the launch config's
/// exact weights-plus-context-plus-graph/backend working set against the machine's effective
/// ceiling (`wiredLimitMB` — inject `effectiveWiredLimitMB(ramGiB:)` at the call site).
func feasibility(
    ramGiB: Double, variant: Variant, flashQuant: FlashQuant,
    ctx: Int, wiredLimitMB: Int, sessions: Int = 1
) -> Feasibility {
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
    }
    let required = requiredWiredMB(
        variant: variant, flashQuant: flashQuant, ctx: ctx, sessions: sessions)
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
