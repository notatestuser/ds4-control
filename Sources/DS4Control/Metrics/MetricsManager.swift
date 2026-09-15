import Foundation
import Combine

@MainActor
final class MetricsManager: ObservableObject {
    @Published var currentSnapshot: SystemSnapshot?
    @Published var history = MetricsHistory(maxEntries: 1800)
    @Published var isRunning = false
    var refreshInterval: TimeInterval = 2.0
    /// Hidden cadence: with the popup closed the app keeps sampling slowly so the graphs stay
    /// continuous (no hole on reopen). 60 s ≈ one ~100 ms power sample per minute — negligible
    /// idle load, and a gap no sparkline can show.
    var backgroundRefreshInterval: TimeInterval = 60.0

    private var timer: Timer?
    private let cpu = CPUCollector()
    private let mem = MemoryCollector()
    private let gpu = GPUCollector()
    private let power = PowerCollector()

    func start() {
        guard !isRunning else { return }
        isRunning = true
        collect()
        installTimer(refreshInterval)
    }
    func stop() { timer?.invalidate(); timer = nil; isRunning = false }

    private func installTimer(_ interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }  // a tick enqueued at deactivation must not sample
                self.collect()
            }
        }
    }

    /// The popup drives the cadence: visible → fast (immediate snapshot + 2 s ticks); hidden →
    /// slow background cadence so the series never gaps. Sampling only fully stops on stop().
    func setActive(_ active: Bool) {
        if active {
            if isRunning {
                installTimer(refreshInterval)
            } else {
                isRunning = true
                collect()
                installTimer(refreshInterval)
            }
        } else if isRunning {
            installTimer(backgroundRefreshInterval)
        }
    }

    func collect() {
        let snap = SystemSnapshot(
            timestamp: Date(),
            cpu: cpu.collect(),
            memory: mem.collect(),
            gpu: gpu.collect(),
            power: power.collect()
        )
        currentSnapshot = snap
        history.append(snap)
    }
}
