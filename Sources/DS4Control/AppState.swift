import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    private let d: UserDefaults

    @Published var ds4Dir: String { didSet { d.set(ds4Dir, forKey: "ds4Dir") } }
    @Published var port: Int { didSet { d.set(port, forKey: "port") } }
    @Published var ctxOverride: Int { didSet { d.set(ctxOverride, forKey: "ctxOverride") } }  // 0 = auto
    @Published var power: Int? { didSet { d.set(power ?? 0, forKey: "power") } }
    @Published var unsupportedLowRAM: Bool { didSet { d.set(unsupportedLowRAM, forKey: "unsupportedLowRAM") } }
    @Published var kvDiskCache: Bool { didSet { d.set(kvDiskCache, forKey: "kvDiskCache") } }
    @Published var selectedVariant: Variant {
        didSet { d.set(selectedVariant.rawValue, forKey: "selectedVariant") }
    }

    init(defaults: UserDefaults = .standard) {
        self.d = defaults
        ds4Dir = d.string(forKey: "ds4Dir") ?? ""
        port = d.object(forKey: "port") as? Int ?? 8000
        ctxOverride = d.integer(forKey: "ctxOverride")
        let p = d.integer(forKey: "power"); power = p > 0 ? p : nil
        unsupportedLowRAM = d.bool(forKey: "unsupportedLowRAM")
        kvDiskCache = d.object(forKey: "kvDiskCache") as? Bool ?? true  // default on
        let ram = systemRamGiB()
        let stored = d.string(forKey: "selectedVariant").flatMap(Variant.init(rawValue:))
        selectedVariant = stored ?? (ram >= 512 ? .pro : .flash)  // default Pro on ≥512 GiB
    }

    func effectiveCtx(ramGiB: Double) -> Int {
        ctxOverride > 0 ? ctxOverride : defaultCtx(ramGiB: ramGiB, variant: selectedVariant)
    }
}
