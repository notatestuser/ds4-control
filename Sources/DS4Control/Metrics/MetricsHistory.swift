import Foundation

final class MetricsHistory: ObservableObject {
    @Published var snapshots: [SystemSnapshot] = []
    let maxEntries: Int
    init(maxEntries: Int = 1800) { self.maxEntries = maxEntries }  // 1h @ 2s
    func append(_ s: SystemSnapshot) {
        snapshots.append(s)
        if snapshots.count > maxEntries { snapshots.removeFirst(snapshots.count - maxEntries) }
    }
    private func series(_ f: (SystemSnapshot) -> Double) -> [(Date, Double)] {
        snapshots.map { ($0.timestamp, f($0)) }
    }
    func cpu() -> [(Date, Double)] { series { $0.cpu.totalUsage } }
    func memory() -> [(Date, Double)] { series { $0.memory.usagePercent } }
    func gpu() -> [(Date, Double)] { series { $0.gpu.utilizationPercent } }
    func power() -> [(Date, Double)] {
        snapshots.compactMap { s in s.power.map { ($0.timestamp, $0.totalPowerWatts) } }
    }
}
