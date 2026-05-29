import Foundation

enum Feasibility: Equatable {
    case standard
    case warnWiredLimit(advisoryMB: Int)   // 96–127 GiB Flash
    case unsupported(reason: String)       // < 96 GiB Flash: allowed only via opt-in toggle
    case blocked(reason: String)           // variant cannot run on this machine
}

/// Physical unified memory in GiB.
func systemRamGiB() -> Double {
    var bytes: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &bytes, &size, nil, 0)
    return Double(bytes) / 1_073_741_824.0
}

func thinkMax(ctx: Int) -> Bool { ctx >= 393_216 }

private let ctxSnapSet = [32_768, 65_536, 131_072, 250_000, 393_216, 1_000_000]

private func snapDown(_ value: Double, ceiling: Int) -> Int {
    let v = min(max(Int(value), 32_768), ceiling)
    return ctxSnapSet.filter { $0 <= v && $0 <= ceiling }.last ?? 32_768
}

/// Budget-derived default context (spec §5.2).
func defaultCtx(ramGiB: Double, variant: Variant) -> Int {
    let reserveGiB = 8.0
    let weightsGiB = Quant.for(variant, ramGiB: ramGiB).weightsGiB
    let budgetBytes = max(0, ramGiB - weightsGiB - reserveGiB) * 1_073_741_824.0
    let raw = budgetBytes / Double(variant.kvBytesPerToken)
    return snapDown(raw, ceiling: variant.ctxCeiling)
}

/// Feasibility gate (spec §5.2). ds4 itself enforces no floor, so the app does.
func feasibility(ramGiB: Double, variant: Variant) -> Feasibility {
    switch variant {
    case .pro:
        return ramGiB >= 512
            ? .standard
            : .blocked(reason: "V4 Pro needs ≥ 512 GiB unified memory.")
    case .flash:
        if ramGiB >= 256 || ramGiB >= 128 { return .standard }       // q4 (≥256) or q2 (128–255)
        if ramGiB >= 96 {
            return .warnWiredLimit(advisoryMB: Int(ramGiB * 1024 * 0.9))
        }
        return .unsupported(reason:
            "V4 Flash needs ≥ 96 GiB. ds4 will begin mmap-loading the ~81 GiB model, but the GPU-wired working set plus KV exceed RAM → swap and instability, not usable generation.")
    }
}
