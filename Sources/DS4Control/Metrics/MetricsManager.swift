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
            Task { @MainActor in self?.collect() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil; isRunning = false }

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
