import Foundation
import IOKit
import CoreFoundation

// FFI to Apple's private IOReport library (libIOReport.dylib in the dyld
// shared cache). Used for per-cluster CPU/GPU power and frequency residency
// data without requiring sudo. Approach is lifted from vladkens/macmon
// (MIT-licensed); see Credits in README.md.

// All CF refs are passed as raw OpaquePointer to bypass Swift's CF bridging
// (which inserts ARC retain/release pairs that conflict with these private
// APIs' undocumented refcount semantics).

@_silgen_name("IOReportCopyChannelsInGroup")
private func IOReportCopyChannelsInGroup(
    _ group: OpaquePointer?,
    _ subgroup: OpaquePointer?,
    _ c: UInt64, _ d: UInt64, _ e: UInt64
) -> OpaquePointer?

@_silgen_name("IOReportMergeChannels")
private func IOReportMergeChannels(
    _ a: OpaquePointer,
    _ b: OpaquePointer,
    _ nilArg: OpaquePointer?
)

@_silgen_name("IOReportCreateSubscription")
private func IOReportCreateSubscription(
    _ a: UnsafeRawPointer?,
    _ chan: OpaquePointer,
    _ outChan: UnsafeMutablePointer<OpaquePointer?>,
    _ d: UInt64,
    _ e: OpaquePointer?
) -> OpaquePointer?

@_silgen_name("IOReportCreateSamples")
private func IOReportCreateSamples(
    _ subs: OpaquePointer,
    _ chan: OpaquePointer,
    _ c: OpaquePointer?
) -> OpaquePointer?

@_silgen_name("IOReportCreateSamplesDelta")
private func IOReportCreateSamplesDelta(
    _ a: OpaquePointer,
    _ b: OpaquePointer,
    _ c: OpaquePointer?
) -> OpaquePointer?

@_silgen_name("IOReportChannelGetGroup")
private func IOReportChannelGetGroup(_ a: OpaquePointer) -> OpaquePointer?

@_silgen_name("IOReportChannelGetSubGroup")
private func IOReportChannelGetSubGroup(_ a: OpaquePointer) -> OpaquePointer?

@_silgen_name("IOReportChannelGetChannelName")
private func IOReportChannelGetChannelName(_ a: OpaquePointer) -> OpaquePointer?

@_silgen_name("IOReportChannelGetUnitLabel")
private func IOReportChannelGetUnitLabel(_ a: OpaquePointer) -> OpaquePointer?

@_silgen_name("IOReportSimpleGetIntegerValue")
private func IOReportSimpleGetIntegerValue(_ a: OpaquePointer, _ b: Int32) -> Int64

@_silgen_name("IOReportStateGetCount")
private func IOReportStateGetCount(_ a: OpaquePointer) -> Int32

@_silgen_name("IOReportStateGetNameForIndex")
private func IOReportStateGetNameForIndex(_ a: OpaquePointer, _ b: Int32) -> OpaquePointer?

@_silgen_name("IOReportStateGetResidency")
private func IOReportStateGetResidency(_ a: OpaquePointer, _ b: Int32) -> Int64

// Helpers to convert raw pointers to Swift strings without intermediate ARC.
private func cfStringFromOpaque(_ p: OpaquePointer?) -> String {
    guard let p else { return "" }
    let cf = Unmanaged<CFString>.fromOpaque(UnsafeRawPointer(p)).takeUnretainedValue()
    return cf as String
}

// MARK: - Public types

/// A single channel's delta sample with values copied out — safe to use after
/// the underlying CFDictionary has been released.
struct IOReportItem {
    let group: String
    let subgroup: String
    let channel: String
    let unit: String
    /// Energy/simple integer value, copied out of the CF dict.
    let simpleValue: Int64
    /// State residencies (name, residency in nanoseconds) — empty for
    /// non-state channels.
    let states: [(name: String, residency: Int64)]
}

// MARK: - Bridge

final class IOReportBridge {
    private let subscription: OpaquePointer
    private let channels: OpaquePointer  // CFMutableDictionaryRef, +1 retained

    /// Subscribe to one or more (group, subgroup) channel pairs.
    /// Returns nil if any group fails to resolve, or on Intel Macs.
    init?(channels groupsToSubscribe: [(group: String, subgroup: String?)]) {
        guard Architecture.isAppleSilicon else { return nil }

        var merged: OpaquePointer?
        for (group, subgroup) in groupsToSubscribe {
            let groupCF = group as CFString
            let groupPtr = OpaquePointer(Unmanaged.passUnretained(groupCF).toOpaque())
            let subgroupPtr: OpaquePointer? = subgroup.map {
                OpaquePointer(Unmanaged.passUnretained($0 as CFString).toOpaque())
            }
            guard let chanPtr = IOReportCopyChannelsInGroup(groupPtr, subgroupPtr, 0, 0, 0) else {
                continue
            }
            // chanPtr is +1 retained per Create rule. Make a mutable copy
            // (+1 retained) and release the immutable original (-1).
            let chanCF = Unmanaged<CFDictionary>.fromOpaque(UnsafeRawPointer(chanPtr)).takeRetainedValue()
            let mutableCopy = CFDictionaryCreateMutableCopy(
                kCFAllocatorDefault,
                CFDictionaryGetCount(chanCF),
                chanCF
            )!
            let mutablePtr = OpaquePointer(Unmanaged.passRetained(mutableCopy).toOpaque())

            if let existing = merged {
                IOReportMergeChannels(existing, mutablePtr, nil)
                Unmanaged<CFMutableDictionary>.fromOpaque(UnsafeRawPointer(mutablePtr)).release()
            } else {
                merged = mutablePtr
            }
        }

        guard let chan = merged else { return nil }
        var subscribedOut: OpaquePointer?
        guard let subs = IOReportCreateSubscription(nil, chan, &subscribedOut, 0, nil) else {
            Unmanaged<CFMutableDictionary>.fromOpaque(UnsafeRawPointer(chan)).release()
            return nil
        }
        if let outPtr = subscribedOut {
            Unmanaged<CFMutableDictionary>.fromOpaque(UnsafeRawPointer(outPtr)).release()
        }

        self.subscription = subs
        self.channels = chan
    }

    /// Take two raw samples spaced by `windowMs` and return the delta channel
    /// items. Mirrors macmon's `get_sample` — a self-contained sample window
    /// per call rather than cross-call state. We use this pattern because
    /// keeping a sample dict alive across collect() calls (storing one as the
    /// next call's "prev" baseline) triggered crashes on macOS 14 / M3 Ultra:
    /// IOReport's internal state appears to alias dict storage across calls
    /// in ways the public refcount rules don't capture.
    func sampleDelta(windowMs: UInt32) -> (items: [IOReportItem], elapsedMs: UInt64)? {
        guard let s1 = IOReportCreateSamples(subscription, channels, nil) else { return nil }
        let start = Date()
        Thread.sleep(forTimeInterval: TimeInterval(windowMs) / 1000.0)
        guard let s2 = IOReportCreateSamples(subscription, channels, nil) else {
            releaseDict(s1)
            return nil
        }
        let elapsedMs = UInt64(Date().timeIntervalSince(start) * 1000.0)

        guard let delta = IOReportCreateSamplesDelta(s1, s2, nil) else {
            releaseDict(s1); releaseDict(s2)
            return nil
        }

        let items = Self.iterate(deltaPtr: delta)
        releaseDict(s1); releaseDict(s2); releaseDict(delta)
        return (items, max(elapsedMs, 1))
    }

    private func releaseDict(_ p: OpaquePointer) {
        Unmanaged<CFDictionary>.fromOpaque(UnsafeRawPointer(p)).release()
    }

    private static func iterate(deltaPtr: OpaquePointer) -> [IOReportItem] {
        let deltaCF = Unmanaged<CFDictionary>.fromOpaque(UnsafeRawPointer(deltaPtr)).takeUnretainedValue()
        let key = "IOReportChannels" as CFString
        guard let arrayPtr = CFDictionaryGetValue(
            deltaCF,
            Unmanaged.passUnretained(key).toOpaque()
        ) else { return [] }
        let array = Unmanaged<CFArray>.fromOpaque(arrayPtr).takeUnretainedValue()
        let count = CFArrayGetCount(array)

        var out: [IOReportItem] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            guard let itemPtr = CFArrayGetValueAtIndex(array, i) else { continue }
            let cfPtr = OpaquePointer(itemPtr)

            let group   = cfStringFromOpaque(IOReportChannelGetGroup(cfPtr))
            let subgrp  = cfStringFromOpaque(IOReportChannelGetSubGroup(cfPtr))
            let channel = cfStringFromOpaque(IOReportChannelGetChannelName(cfPtr))
            let unit    = cfStringFromOpaque(IOReportChannelGetUnitLabel(cfPtr))
                            .trimmingCharacters(in: .whitespacesAndNewlines)

            let stateCount = IOReportStateGetCount(cfPtr)
            var states: [(String, Int64)] = []
            var simple: Int64 = 0
            if stateCount > 0 {
                states.reserveCapacity(Int(stateCount))
                for j in 0..<stateCount {
                    let name = cfStringFromOpaque(IOReportStateGetNameForIndex(cfPtr, j))
                    let res = IOReportStateGetResidency(cfPtr, j)
                    states.append((name, res))
                }
            } else {
                simple = IOReportSimpleGetIntegerValue(cfPtr, 0)
            }

            out.append(IOReportItem(
                group: group, subgroup: subgrp, channel: channel,
                unit: unit, simpleValue: simple, states: states
            ))
        }
        return out
    }

    // MARK: - Channel-item helpers (operate on already-resolved IOReportItem)

    /// Convert an Energy Model item to Watts using its energy unit and the
    /// elapsed sample window. Energy / time = power.
    static func watts(item: IOReportItem, elapsedMs: UInt64) -> Double? {
        let perSecond = Double(item.simpleValue) / (Double(elapsedMs) / 1000.0)
        switch item.unit {
        case "mJ": return perSecond / 1e3
        case "uJ": return perSecond / 1e6
        case "nJ": return perSecond / 1e9
        default:   return nil
        }
    }

    deinit {
        Unmanaged<CFMutableDictionary>.fromOpaque(UnsafeRawPointer(channels)).release()
        // The subscription handle has no public release in the IOReport
        // headers; macmon CFRelease's it but we treat the OpaquePointer as
        // permanent for the bridge's lifetime. Process exit cleans it up.
    }
}
