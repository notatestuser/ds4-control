import Foundation
import Darwin

final class MemoryCollector {

    func collect() -> MemoryMetrics {
        let timestamp = Date()
        let pageSize = UInt64(vm_kernel_page_size)

        // Get total physical memory via sysctl
        var totalBytes: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &totalBytes, &size, nil, 0)

        // Get VM statistics
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(
                    mach_host_self(),
                    HOST_VM_INFO64,
                    intPtr,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else {
            return MemoryMetrics(
                timestamp: timestamp,
                totalBytes: totalBytes,
                usedBytes: 0,
                wiredBytes: 0,
                compressedBytes: 0,
                swapUsedBytes: 0,
                pressureLevel: .nominal
            )
        }

        let activeBytes = UInt64(vmStats.active_count) * pageSize
        let wiredBytes = UInt64(vmStats.wire_count) * pageSize
        let compressedBytes = UInt64(vmStats.compressor_page_count) * pageSize
        // Match Activity Monitor's "Memory Used" = App Memory + Wired + Compressed
        let usedBytes = activeBytes + wiredBytes + compressedBytes

        // Swap usage via sysctl
        let swapUsedBytes = Self.getSwapUsed()

        let pressure: MemoryPressure
        let usageFraction = Double(usedBytes) / Double(totalBytes)
        if usageFraction > 0.90 {
            pressure = .critical
        } else if usageFraction > 0.75 {
            pressure = .warning
        } else {
            pressure = .nominal
        }

        return MemoryMetrics(
            timestamp: timestamp,
            totalBytes: totalBytes,
            usedBytes: usedBytes,
            wiredBytes: wiredBytes,
            compressedBytes: compressedBytes,
            swapUsedBytes: swapUsedBytes,
            pressureLevel: pressure
        )
    }

    /// Read swap usage via sysctl vm.swapusage (xsw_usage struct).
    private static func getSwapUsed() -> UInt64 {
        var swapUsage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let ret = sysctlbyname("vm.swapusage", &swapUsage, &size, nil, 0)
        guard ret == 0 else { return 0 }
        return swapUsage.xsu_used
    }
}
