import Foundation

enum Feasibility: Equatable {
    case standard
    case warnWiredLimit(advisoryMB: Int)  // 96–127 GiB Flash
    case unsupported(reason: String)  // < 96 GiB Flash: allowed only via opt-in toggle
    case blocked(reason: String)  // variant cannot run on this machine
}

/// Physical unified memory in GiB.
func systemRamGiB() -> Double {
    var bytes: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &bytes, &size, nil, 0)
    return Double(bytes) / 1_073_741_824.0
}

func thinkMax(ctx: Int) -> Bool { ctx >= 393_216 }

private let ctxSnapSet = [32_768, 65_536, 131_072, 250_000, 393_216, 786_432, 1_000_000]

/// Cap for the budget-derived *default* context. Set to the 1M ceiling so a Pro
/// machine with the memory budget defaults to the full context window; Flash and
/// smaller machines stay bounded by their memory budget and `variant.ctxCeiling`.
private let defaultCtxCap = 1_000_000

/// Headroom left for macOS and other processes — also the buffer the Metal
/// wired-limit advisory leaves below total RAM.
private let osReserveGiB = 8.0

/// Suggested `iogpu.wired_limit_mb`: total RAM minus the OS reserve, so the GPU-wired
/// working set (weights + KV) fits. A percentage heuristic under-shoots the largest
/// models (e.g. 0.9·512 GiB ≈ 460 GiB < Pro's ~471 GiB working set).
private func wiredLimitAdvisoryMB(ramGiB: Double) -> Int { Int((ramGiB - osReserveGiB) * 1024) }

private func snapDown(_ value: Double, ceiling: Int) -> Int {
    let v = min(max(Int(value), 32_768), ceiling)
    return ctxSnapSet.filter { $0 <= v && $0 <= ceiling }.last ?? 32_768
}

/// Budget-derived default context (spec §5.2).
func defaultCtx(ramGiB: Double, variant: Variant) -> Int {
    let weightsGiB = Quant.for(variant, ramGiB: ramGiB).weightsGiB
    let budgetBytes = max(0, ramGiB - weightsGiB - osReserveGiB) * 1_073_741_824.0
    let raw = min(budgetBytes / Double(variant.kvBytesPerToken), Double(defaultCtxCap))
    return snapDown(raw, ceiling: variant.ctxCeiling)
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
        if ramGiB >= 128 { return .standard }  // Flash standard ≥128 GiB (q4 ≥256, q2 128–255)
        if ramGiB >= 96 {
            return .warnWiredLimit(advisoryMB: wiredLimitAdvisoryMB(ramGiB: ramGiB))
        }
        return .unsupported(
            reason:
                "V4 Flash needs ≥ 96 GiB. ds4 will begin mmap-loading the ~81 GiB model, but the GPU-wired working set plus KV exceed RAM → swap and instability, not usable generation."
        )
    }
}
