import Foundation
import Metal

enum Feasibility: Equatable {
    case standard
    /// The launch config's GPU-wired working set (weights + resident context allocations) exceeds the machine's
    /// effective Metal wired limit. Starting anyway pages the model and hangs the machine,
    /// so Start is gated until the limit is raised (an explicit "Start anyway" override
    /// remains). `advisoryMB` is the sysctl value that makes this config fit.
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

/// Test/dev override: when `DS4_EMULATE_WIRED_LIMIT_MB` is a positive integer, the
/// effective limit reports that instead of the machine's real one — so the gated-Start
/// notice can be exercised without touching the sysctl (no sudo needed).
func emulatedWiredLimitMB() -> Int? {
    guard let raw = ProcessInfo.processInfo.environment["DS4_EMULATE_WIRED_LIMIT_MB"],
        let mb = Int(raw), mb > 0
    else { return nil }
    return mb
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

func thinkMax(ctx: Int) -> Bool { ctx >= thinkMaxMinCtx }

/// Headroom left for macOS and other processes — also the buffer the Metal
/// wired-limit advisory leaves below total RAM.
private let osReserveGiB = 8.0
let maxConcurrentSessions = 16

/// Suggested `iogpu.wired_limit_mb`: total RAM minus the OS reserve, so the GPU-wired
/// working set (weights + resident context allocations) fits. A percentage heuristic under-shoots the largest
/// models (e.g. 0.9·512 GiB ≈ 460 GiB < Pro's ~471 GiB working set).
func wiredLimitAdvisoryMB(ramGiB: Double) -> Int { Int((ramGiB - osReserveGiB) * 1024) }

private let bytesPerMiB = 1024 * 1024

private struct MetalContextShape {
    let ratio4Layers: Int
    let ratio128Layers: Int
    let longPromptPrefillCap: Int
}

private func metalContextShape(for variant: Variant) -> MetalContextShape {
    switch variant {
    case .flash:
        return MetalContextShape(ratio4Layers: 21, ratio128Layers: 20, longPromptPrefillCap: 4096)
    case .pro:
        return MetalContextShape(ratio4Layers: 30, ratio128Layers: 31, longPromptPrefillCap: 8192)
    }
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

    let shape = metalContextShape(for: variant)
    let prefillCap = ctx > 4096 ? min(shape.longPromptPrefillCap, ctx) : ctx
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

/// The GPU-wired working set ds4 needs for this launch config (MB): exact resident
/// GGUF bytes plus ds4's Metal context allocation for every resident session. Context
/// counts regardless of the disk KV cache: disk storage checkpoints resident tensors;
/// it does not replace them.
func requiredWiredMB(variant: Variant, flashQuant: FlashQuant, ctx: Int, sessions: Int = 1) -> Int {
    let quant = Quant.for(variant, flashQuant: flashQuant)
    guard
        let weightsMB = roundedUpMiB(quant.ggufBytes),
        let sessionBytes = metalContextBytes(variant: variant, ctx: ctx)
    else { return Int.max }
    let (contextBytes, sessionOverflow) = sessionBytes.multipliedReportingOverflow(by: max(sessions, 1))
    guard !sessionOverflow, let contextMB = roundedUpMiB(contextBytes) else { return Int.max }
    let (requiredMB, totalOverflow) = weightsMB.addingReportingOverflow(contextMB)
    return totalOverflow ? Int.max : requiredMB
}

func launchBoundsError(variant: Variant, ctx: Int, sessions: Int) -> String? {
    guard (1...variant.ctxCeiling).contains(ctx) else {
        return "Context size must be between 1 and \(variant.ctxCeiling) tokens."
    }
    guard (1...maxConcurrentSessions).contains(sessions) else {
        return "Concurrent sessions must be between 1 and \(maxConcurrentSessions)."
    }
    return nil
}

/// Default context, tiered by machine memory (measured via scripts/flash-mem-harness.sh,
/// where q2 @1M ≈ 96 GiB resident): V4 Pro and ≥128 GiB Flash (q2-q4 quant) run the full 1M
/// window all-resident; 96–127 GiB Flash (q2) is capped at 393K ("Think-Max") so weights and
/// resident context allocations
/// stay resident without paging. `flashQuant` is accepted for API symmetry; the tier keys on RAM.
func defaultCtx(ramGiB: Double, variant: Variant, flashQuant: FlashQuant) -> Int {
    if variant == .pro { return variant.ctxCeiling }  // Pro: full 1M
    return ramGiB >= 128 ? variant.ctxCeiling : 393_216  // Flash: 1M on ≥128 GiB, else 393K
}

/// Whether a Flash quant's resident weights fit this machine (weights + OS reserve ≤ RAM).
/// Drives which options the Settings quant picker offers.
func flashQuantFits(_ q: FlashQuant, ramGiB: Double) -> Bool {
    let bytesPerGiB = 1_073_741_824.0
    return Double(q.quant.ggufBytes) + osReserveGiB * bytesPerGiB <= ramGiB * bytesPerGiB
}

/// Default Flash quant: q2-q4 on ≥128 GiB (room for the 1M window all-resident), else q2
/// (96–127 GiB). Only used when nothing is persisted yet.
func defaultFlashQuant(ramGiB: Double) -> FlashQuant {
    ramGiB >= 128 ? .q2q4 : .q2
}

/// Feasibility gate (spec §5.2). ds4 itself enforces no floor, so the app does. The RAM
/// tiers block outright; the Metal wired-limit check then gates the launch config's
/// exact weights-plus-context working set against the machine's effective ceiling (`wiredLimitMB` —
/// inject `effectiveWiredLimitMB(ramGiB:)` at the call site).
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
                    "V4 Flash needs ≥ 96 GiB unified memory. Below that, the ~81 GiB model plus its KV cache exceed RAM, so it can't run."
            )
        }
    }
    let required = requiredWiredMB(
        variant: variant, flashQuant: flashQuant, ctx: ctx, sessions: sessions)
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
