import Foundation

enum Feasibility: Equatable {
    case standard
    case warnWiredLimit(advisoryMB: Int)  // 96–127 GiB Flash
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

func thinkMax(ctx: Int) -> Bool { ctx >= 393_216 }

/// Headroom left for macOS and other processes — also the buffer the Metal
/// wired-limit advisory leaves below total RAM.
private let osReserveGiB = 8.0

/// Suggested `iogpu.wired_limit_mb`: total RAM minus the OS reserve, so the GPU-wired
/// working set (weights + KV) fits. A percentage heuristic under-shoots the largest
/// models (e.g. 0.9·512 GiB ≈ 460 GiB < Pro's ~471 GiB working set).
private func wiredLimitAdvisoryMB(ramGiB: Double) -> Int { Int((ramGiB - osReserveGiB) * 1024) }

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

/// Feasibility gate (spec §5.2). ds4 itself enforces no floor, so the app does.
func feasibility(ramGiB: Double, variant: Variant) -> Feasibility {
    switch variant {
    case .pro:
        guard ramGiB >= 512 else { return .blocked(reason: "V4 Pro needs ≥ 512 GiB unified memory.") }
        // Pro's ~432 GiB weights + KV exceed the default Metal wired limit even on a
        // 512 GiB machine, so always advise raising it.
        return .warnWiredLimit(advisoryMB: wiredLimitAdvisoryMB(ramGiB: ramGiB))
    case .flash:
        if ramGiB >= 128 { return .standard }  // ≥128 GiB: q2-q4 quant, 1M context
        if ramGiB >= 96 {  // 96–127 GiB: q2 quant, 393K context
            return .warnWiredLimit(advisoryMB: wiredLimitAdvisoryMB(ramGiB: ramGiB))
        }
        return .blocked(
            reason:
                "V4 Flash needs ≥ 96 GiB unified memory. Below that, the ~81 GiB model plus its KV cache exceed RAM, so it can't run."
        )
    }
}
