import Foundation
import IOKit

// Reads dynamic voltage/frequency scaling (DVFS) tables out of the
// AppleARMIODevice/pmgr IORegistry node — the same source powermetrics uses.
// Approach is lifted from vladkens/macmon (MIT). On M1–M3 the freqs are
// stored in Hz; M4+ stores them in kHz.

struct SoCInfo {
    let chipName: String
    let ecpuFreqsMHz: [UInt32]      // ascending, [0] is base, [last] is max
    let pcpuFreqsMHz: [UInt32]
    let gpuFreqsMHz: [UInt32]       // includes a leading "off" entry on some chips

    static func read() -> SoCInfo? {
        guard Architecture.isAppleSilicon else { return nil }

        let chip = detectChipName()
        let cpuScale: UInt32 = chip.contains("M1") || chip.contains("M2") || chip.contains("M3")
            ? 1_000_000  // Hz → MHz
            : 1_000      // kHz → MHz
        let gpuScale: UInt32 = chip.contains("M1") || chip.contains("M2") || chip.contains("M3")
            ? 1_000_000
            : 1_000

        var ecpu: [UInt32] = []
        var pcpu: [UInt32] = []
        var gpu:  [UInt32] = []

        var iterator: io_iterator_t = 0
        let match = IOServiceMatching("AppleARMIODevice")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }

            // Filter by node name (only "pmgr" carries the voltage-states blobs)
            var nameBuf = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(entry, &nameBuf) == KERN_SUCCESS,
                  String(cString: nameBuf) == "pmgr" else { continue }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else { continue }

            // Cluster keys: voltage-states1-sram = ECPU, voltage-states5-sram = PCPU,
            // voltage-states9 = GPU. Each blob is repeating (freq:u32, voltage:u32).
            // (M5 chips with a third tier need a different mapping; we match
            // macmon's M1–M4 default for now.)
            ecpu = parseFreqBlob(dict["voltage-states1-sram"], scale: cpuScale)
            pcpu = parseFreqBlob(dict["voltage-states5-sram"], scale: cpuScale)
            gpu  = parseFreqBlob(dict["voltage-states9"],      scale: gpuScale)
            break
        }

        guard !ecpu.isEmpty, !pcpu.isEmpty else { return nil }
        return SoCInfo(chipName: chip, ecpuFreqsMHz: ecpu, pcpuFreqsMHz: pcpu, gpuFreqsMHz: gpu)
    }

    private static func parseFreqBlob(_ raw: Any?, scale: UInt32) -> [UInt32] {
        guard let data = raw as? Data, data.count >= 8 else { return [] }
        var out: [UInt32] = []
        out.reserveCapacity(data.count / 8)
        data.withUnsafeBytes { buf in
            let base = buf.baseAddress!
            for offset in stride(from: 0, to: data.count, by: 8) {
                let freqLE = base.load(fromByteOffset: offset, as: UInt32.self)
                let freq = UInt32(littleEndian: freqLE)
                if scale > 0 {
                    out.append(freq / scale)
                } else {
                    out.append(freq)
                }
            }
        }
        return out
    }

    private static func detectChipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
