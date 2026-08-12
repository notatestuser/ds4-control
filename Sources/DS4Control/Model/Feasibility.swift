import Foundation
import Metal

enum Feasibility: Equatable {
    case standard
    /// The launch config's GPU-wired working set (weights + resident KV allocations) exceeds the machine's
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
/// working set (weights + KV) fits. A percentage heuristic under-shoots the largest
/// models (e.g. 0.9·512 GiB ≈ 460 GiB < Pro's ~471 GiB working set).
func wiredLimitAdvisoryMB(ramGiB: Double) -> Int { Int((ramGiB - osReserveGiB) * 1024) }

/// The GPU-wired working set ds4 needs for this launch config (MB): resident weights plus
/// the KV cache at the launch context for every resident session. KV counts regardless of
/// the disk KV cache: ds4 creates the resident session tensors first, then uses the disk
/// store only to checkpoint and restore their contents. The harness measures ~16 GiB of
/// context buffers at 1M with disk KV enabled.
/// Grounded in scripts/flash-mem-harness.sh, where q2 @1M ≈ 96 GiB resident ≈ weights + KV.
func requiredWiredMB(variant: Variant, flashQuant: FlashQuant, ctx: Int, sessions: Int = 1) -> Int {
    let quant = Quant.for(variant, flashQuant: flashQuant)
    let weightsMB = Int(quant.weightsGiB * 1024)
    guard ctx >= 0 else { return Int.max }
    let (sessionBytes, contextOverflow) = variant.kvBytesPerToken.multipliedReportingOverflow(by: ctx)
    let (kvBytes, sessionOverflow) = sessionBytes.multipliedReportingOverflow(by: max(sessions, 1))
    guard !contextOverflow, !sessionOverflow else { return Int.max }
    let kvMB = kvBytes / (1024 * 1024)
    let (requiredMB, totalOverflow) = weightsMB.addingReportingOverflow(kvMB)
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
/// window all-resident; 96–127 GiB Flash (q2) is capped at 393K ("Think-Max") so weights + KV
/// stay resident without paging. `flashQuant` is accepted for API symmetry; the tier keys on RAM.
func defaultCtx(ramGiB: Double, variant: Variant, flashQuant: FlashQuant) -> Int {
    if variant == .pro { return variant.ctxCeiling }  // Pro: full 1M
    return ramGiB >= 128 ? variant.ctxCeiling : 393_216  // Flash: 1M on ≥128 GiB, else 393K
}

/// Whether a Flash quant's resident weights fit this machine (weights + OS reserve ≤ RAM).
/// Drives which options the Settings quant picker offers.
func flashQuantFits(_ q: FlashQuant, ramGiB: Double) -> Bool {
    q.quant.weightsGiB + osReserveGiB <= ramGiB
}

/// Default Flash quant: q2-q4 on ≥128 GiB (room for the 1M window all-resident), else q2
/// (96–127 GiB). Only used when nothing is persisted yet.
func defaultFlashQuant(ramGiB: Double) -> FlashQuant {
    ramGiB >= 128 ? .q2q4 : .q2
}

/// Feasibility gate (spec §5.2). ds4 itself enforces no floor, so the app does. The RAM
/// tiers block outright; the Metal wired-limit check then gates the launch config's
/// weights-plus-KV working set against the machine's effective ceiling (`wiredLimitMB` —
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
    if Double(required) > ramGiB * 1024 {
        return .blocked(
            reason:
                "This setup needs ~\(required / 1024) GiB unified memory, but this Mac has ~\(Int(ramGiB)) GiB. Reduce context or concurrent sessions."
        )
    }
    if wiredLimitMB < required {
        let advisory = max(required, wiredLimitAdvisoryMB(ramGiB: ramGiB))
        return .wiredLimitTooLow(requiredMB: required, advisoryMB: advisory)
    }
    return .standard
}
