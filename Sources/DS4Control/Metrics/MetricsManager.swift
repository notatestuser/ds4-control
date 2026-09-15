import Foundation
import Combine

@MainActor
final class MetricsManager: ObservableObject {
    @Published var currentSnapshot: SystemSnapshot?
    @Published var history = MetricsHistory(maxEntries: 1800)
    @Published var isRunning = false
    var refreshInterval: TimeInterval = 2.0

    private var timer: Timer?
    private let cpu = CPUCollector()
    private let mem = MemoryCollector()
    private let gpu = GPUCollector()
    private let power = PowerCollector()

    func start() {
        guard !isRunning else { return }
        isRunning = true
        collect()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }  // a tick enqueued at deactivation must not sample
                self.collect()
            }
        }
    }
    func stop() { timer?.invalidate(); timer = nil; isRunning = false }

    /// Collection runs only while something is actively watching — the popup. Closing it stops
    /// the timer, so an idle menu-bar app wakes no timers and samples nothing (each tick also
    /// blocks the main thread ~100 ms in the power sampler). Reopening restarts collection
    /// with an immediate snapshot.
    func setActive(_ active: Bool) {
        if active { start() } else { stop() }
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
