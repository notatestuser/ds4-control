import Foundation
import Darwin

final class CPUCollector {
    private var previousTicks: [UInt64]? // [user, system, idle, nice] per core flattened

    func collect() -> CPUMetrics {
        let timestamp = Date()
        var numCPUsU: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUsU,
            &cpuInfo,
            &cpuInfoCount
        )

        guard result == KERN_SUCCESS, let info = cpuInfo else {
            return CPUMetrics(
                timestamp: timestamp,
                totalUsage: 0,
                coreCount: 0
            )
        }

        let numCPUs = Int(numCPUsU)
        // Each core has CPU_STATE_MAX (4) entries: user, system, idle, nice
        let stateCount = Int(CPU_STATE_MAX)

        // Read current ticks
        var currentTicks = [UInt64](repeating: 0, count: numCPUs * stateCount)
        for core in 0..<numCPUs {
            let base = core * stateCount
            let infoBase = Int32(core) * CPU_STATE_MAX
            currentTicks[base + 0] = UInt64(info[Int(infoBase + CPU_STATE_USER)])
            currentTicks[base + 1] = UInt64(info[Int(infoBase + CPU_STATE_SYSTEM)])
            currentTicks[base + 2] = UInt64(info[Int(infoBase + CPU_STATE_IDLE)])
            currentTicks[base + 3] = UInt64(info[Int(infoBase + CPU_STATE_NICE)])
        }

        // Deallocate the processor info
        let deallocSize = vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), deallocSize)

        // Calculate deltas
        var totalUser: UInt64 = 0
        var totalSystem: UInt64 = 0
        var totalIdle: UInt64 = 0

        if let prev = previousTicks, prev.count == currentTicks.count {
            for core in 0..<numCPUs {
                let base = core * stateCount
                let dUser = currentTicks[base + 0] - prev[base + 0]
                let dSystem = currentTicks[base + 1] - prev[base + 1]
                let dIdle = currentTicks[base + 2] - prev[base + 2]
                let dNice = currentTicks[base + 3] - prev[base + 3]

                totalUser += dUser + dNice
                totalSystem += dSystem
                totalIdle += dIdle
            }
        }

        previousTicks = currentTicks

        let grandTotal = totalUser + totalSystem + totalIdle
        let userPct: Double
        let systemPct: Double

        if grandTotal > 0 {
            userPct = Double(totalUser) / Double(grandTotal) * 100.0
            systemPct = Double(totalSystem) / Double(grandTotal) * 100.0
        } else {
            userPct = 0
            systemPct = 0
        }

        return CPUMetrics(
            timestamp: timestamp,
            totalUsage: userPct + systemPct,
            coreCount: numCPUs
        )
    }
}
