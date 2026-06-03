import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    private let d: UserDefaults

    @Published var port: Int { didSet { d.set(port, forKey: "port") } }
    @Published var ctxOverride: Int { didSet { d.set(ctxOverride, forKey: "ctxOverride") } }  // 0 = auto
    @Published var power: Int? { didSet { d.set(power ?? 0, forKey: "power") } }
    @Published var kvDiskCache: Bool { didSet { d.set(kvDiskCache, forKey: "kvDiskCache") } }
    /// Send `reasoning_effort: max` from the built-in chat so ds4 runs Think Max (engages only
    /// when the server --ctx ≥ 393,216, which the defaults guarantee). Off = the chat's fast
    /// no-think path. Coding-agent CLIs set their own per-request level, so this affects only chat.
    @Published var thinkMaxChat: Bool { didSet { d.set(thinkMaxChat, forKey: "thinkMaxChat") } }
    /// High-performance downloads (more parallel connections). Off by default: capped
    /// concurrency keeps the connection count CGNAT-safe. See SupervisorService.download.
    @Published var highPerformanceDownload: Bool {
        didSet { d.set(highPerformanceDownload, forKey: "highPerformanceDownload") }
    }
    @Published var selectedVariant: Variant {
        didSet { d.set(selectedVariant.rawValue, forKey: "selectedVariant") }
    }
    /// User-selected V4 Flash quant (default q2-q4-imatrix). Drives the Flash download/run
    /// filename and the auto-context calc; V4 Pro ignores it.
    @Published var selectedFlashQuant: FlashQuant {
        didSet { d.set(selectedFlashQuant.rawValue, forKey: "selectedFlashQuant") }
    }

    init(defaults: UserDefaults = .standard) {
        self.d = defaults
        port = d.object(forKey: "port") as? Int ?? 8000
        ctxOverride = d.integer(forKey: "ctxOverride")
        let p = d.integer(forKey: "power"); power = p > 0 ? p : nil
        kvDiskCache = d.object(forKey: "kvDiskCache") as? Bool ?? true  // default on
        thinkMaxChat = d.bool(forKey: "thinkMaxChat")  // default off
        highPerformanceDownload = d.bool(forKey: "highPerformanceDownload")  // default off
        let ram = systemRamGiB()
        let stored = d.string(forKey: "selectedVariant").flatMap(Variant.init(rawValue:))
        selectedVariant = stored ?? (ram >= 512 ? .pro : .flash)  // default Pro on ≥512 GiB
        let storedQuant = d.string(forKey: "selectedFlashQuant").flatMap(FlashQuant.init(rawValue:))
        selectedFlashQuant = storedQuant ?? defaultFlashQuant(ramGiB: ram)  // default q2-q4-imatrix
    }

    func effectiveCtx(ramGiB: Double) -> Int {
        ctxOverride > 0
            ? ctxOverride
            : defaultCtx(ramGiB: ramGiB, variant: selectedVariant, flashQuant: selectedFlashQuant)
    }
}
