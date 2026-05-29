import Foundation

struct CPUMetrics {
    let timestamp: Date
    let totalUsage: Double        // 0–100
    let coreCount: Int
}

enum MemoryPressure: String { case nominal = "Nominal", warning = "Warning", critical = "Critical" }

struct MemoryMetrics {
    let timestamp: Date
    let totalBytes: UInt64
    let usedBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let swapUsedBytes: UInt64
    let pressureLevel: MemoryPressure
    var usagePercent: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) * 100 : 0 }
}

struct GPUMetrics {
    let timestamp: Date
    let utilizationPercent: Double
    let coreCount: Int
    let chipName: String
}

struct PowerMetrics {
    let timestamp: Date
    let cpuPowerWatts: Double
    let gpuPowerWatts: Double
    let anePowerWatts: Double
    let totalPowerWatts: Double
}

struct SystemSnapshot: Identifiable {
    let id = UUID()
    let timestamp: Date
    let cpu: CPUMetrics
    let memory: MemoryMetrics
    let gpu: GPUMetrics
    let power: PowerMetrics?
}
