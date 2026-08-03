import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    static let defaultHost = "127.0.0.1"

    private let d: UserDefaults

    @Published var port: Int { didSet { d.set(port, forKey: "port") } }
    @Published var host: String { didSet { d.set(host, forKey: "host") } }
    @Published var ctxOverride: Int { didSet { d.set(ctxOverride, forKey: "ctxOverride") } }  // 0 = auto
    @Published var power: Int? { didSet { d.set(power ?? 0, forKey: "power") } }
    /// Resident KV sessions ds4-server preallocates (`--batched-session N`). 1 omits the flag,
    /// keeping the original single-session path. Memory grows with sessions × context.
    @Published var concurrentSessions: Int { didSet { d.set(concurrentSessions, forKey: "concurrentSessions") } }
    @Published var kvDiskCache: Bool { didSet { d.set(kvDiskCache, forKey: "kvDiskCache") } }
    /// The chat's thinking level (Off / Standard / Max Think). Coding-agent CLIs set their
    /// own per-request level, so this affects only the built-in chat.
    @Published var thinkingMode: ThinkingMode { didSet { d.set(thinkingMode.rawValue, forKey: "thinkingMode") } }
    /// High-performance downloads (64 parallel connections). Off by default: 8 connections
    /// keeps the connection count CGNAT-safe. See SupervisorService.download.
    @Published var highPerformanceDownload: Bool {
        didSet { d.set(highPerformanceDownload, forKey: "highPerformanceDownload") }
    }
    /// One-time migration: the 0731 Flash weights orphaned the preview GGUFs. Until the
    /// user answers the popup banner, they get a delete-and-reclaim offer. The key is
    /// generation-versioned so a future weights refresh re-prompts.
    @Published var legacyWeightsPromptDismissed: Bool {
        didSet { d.set(legacyWeightsPromptDismissed, forKey: "legacyWeightsPromptDismissed0731") }
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
        host = d.string(forKey: "host") ?? Self.defaultHost
        ctxOverride = d.integer(forKey: "ctxOverride")
        let p = d.integer(forKey: "power"); power = p > 0 ? p : nil
        let sessions = d.integer(forKey: "concurrentSessions")
        concurrentSessions = sessions >= 1 ? min(sessions, 16) : 1  // default 1, clamp 1...16
        kvDiskCache = d.object(forKey: "kvDiskCache") as? Bool ?? true  // default on
        if let storedMode = d.string(forKey: "thinkingMode").flatMap(ThinkingMode.init(rawValue:)) {
            thinkingMode = storedMode
        } else if d.object(forKey: "thinkMaxChat") != nil {
            thinkingMode = d.bool(forKey: "thinkMaxChat") ? .max : .off  // legacy toggle migration
        } else {
            thinkingMode = .standard  // fresh-install default
        }
        highPerformanceDownload = d.bool(forKey: "highPerformanceDownload")  // default off
        legacyWeightsPromptDismissed = d.bool(forKey: "legacyWeightsPromptDismissed0731")  // default false
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

    /// Set the chat's thinking level. `.max` needs a context ≥ 393,216 (ds4's floor); below
    /// it this returns `.needsCtxBump` WITHOUT changing the mode, so the caller can ask the
    /// user about bumping the context first.
    func requestThinkingMode(_ mode: ThinkingMode, currentCtx: Int) -> ThinkingModeGate {
        if mode == .max && !thinkMax(ctx: currentCtx) { return .needsCtxBump }
        thinkingMode = mode
        return .applied
    }

    /// The user confirmed the context bump: pin the override to ds4's Max Think floor and
    /// enable `.max`. (Restarting a running server is the caller's job.)
    func applyMaxThinkCtxBump() {
        ctxOverride = thinkMaxMinCtx
        thinkingMode = .max
    }

    func normalizeHostForLaunch() -> String {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
        host = normalized.isEmpty ? Self.defaultHost : normalized
        return host
    }
}
