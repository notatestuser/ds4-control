import Foundation
import IOKit

final class GPUCollector {

    private lazy var chipName: String = Self.detectChipName()

    func collect() -> GPUMetrics {
        let timestamp = Date()

        // Query IOAccelerator for GPU utilization on Apple Silicon
        var utilization = 0.0
        var gpuCoreCount = 0

        let matchDict = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator)

        if result == KERN_SUCCESS {
            var service = IOIteratorNext(iterator)
            while service != 0 {
                var properties: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                    let dict = properties?.takeRetainedValue() as? [String: Any]
                {

                    // "PerformanceStatistics" contains GPU utilization data
                    if let perfStats = dict["PerformanceStatistics"] as? [String: Any] {
                        // Different keys depending on GPU generation
                        if let gpuUtil = perfStats["GPU Activity(%)"] as? NSNumber {
                            utilization = gpuUtil.doubleValue
                        } else if let deviceUtil = perfStats["Device Utilization %"] as? NSNumber {
                            utilization = deviceUtil.doubleValue
                        } else if let gpuActivity = perfStats["gpuActivity"] as? NSNumber {
                            utilization = gpuActivity.doubleValue
                        }

                        if let cores = perfStats["GPU Core Count"] as? Int {
                            gpuCoreCount = cores
                        }
                    }

                    // Fallback: try to get core count from top-level properties
                    if gpuCoreCount == 0, let cores = dict["gpu-core-count"] as? Int {
                        gpuCoreCount = cores
                    }
                }

                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }

        if gpuCoreCount == 0 {
            gpuCoreCount = Self.defaultGPUCoreCount(for: chipName)
        }

        return GPUMetrics(
            timestamp: timestamp,
            utilizationPercent: utilization,
            coreCount: gpuCoreCount,
            chipName: chipName
        )
    }

    private static func detectChipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let raw = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "Apple Silicon" : raw
    }

    private static func defaultGPUCoreCount(for chip: String) -> Int {
        // Rough fallbacks when IOKit doesn't report a core count. Not
        // exhaustive — users can see 0 here if detection fails entirely.
        let lower = chip.lowercased()
        if lower.contains("m3 ultra") { return 80 }
        if lower.contains("m2 ultra") { return 76 }
        if lower.contains("m1 ultra") { return 64 }
        if lower.contains("m4 max") { return 40 }
        if lower.contains("m3 max") { return 40 }
        if lower.contains("m2 max") { return 38 }
        if lower.contains("m1 max") { return 32 }
        if lower.contains("m4 pro") { return 20 }
        if lower.contains("m3 pro") { return 18 }
        if lower.contains("m2 pro") { return 19 }
        if lower.contains("m1 pro") { return 16 }
        return 0
    }
}
