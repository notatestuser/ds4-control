import Foundation
import CoreFoundation

// Sample loop and channel-matching adapted from vladkens/macmon (MIT).

final class PowerCollector {

    private let bridge: IOReportBridge?

    init() {
        guard Architecture.isAppleSilicon else {
            self.bridge = nil
            return
        }
        self.bridge = IOReportBridge(channels: [
            ("Energy Model", nil),                              // CPU/GPU/ANE power
        ])
    }

    // 100 ms window: long enough to give Energy Model channels a stable
    // reading (~10 mJ at 0.1 W idle), short enough to keep the 2 s collect
    // tick fluid. macmon defaults to 1000 ms in their TUI; we don't have
    // that luxury since the rest of the dashboard is also waiting.
    private let sampleWindowMs: UInt32 = 100

    /// Returns nil on Intel or when IOReport is otherwise unavailable.
    /// Blocks the calling thread for ~`sampleWindowMs` while sampling.
    func collect() -> PowerMetrics? {
        guard let bridge else { return nil }
        guard let (items, elapsedMs) = bridge.sampleDelta(windowMs: sampleWindowMs) else { return nil }

        var cpuW = 0.0
        var gpuW = 0.0
        var aneW = 0.0

        for it in items where it.group == "Energy Model" {
            guard let w = IOReportBridge.watts(item: it, elapsedMs: elapsedMs) else { continue }
            let ch = it.channel
            if ch == "GPU Energy" {
                gpuW += w
            } else if ch.hasSuffix("CPU Energy") {       // "CPU Energy" or "DIE_N_CPU Energy" on Ultra
                cpuW += w
            } else if ch.hasPrefix("ANE") {              // "ANE", "ANE0", "ANE0_N"
                aneW += w
            }
        }

        return PowerMetrics(
            timestamp: Date(),
            cpuPowerWatts: cpuW,
            gpuPowerWatts: gpuW,
            anePowerWatts: aneW,
            totalPowerWatts: cpuW + gpuW + aneW
        )
    }
}
