import Foundation
import Combine
import ServiceManagement

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
    /// Whether DS4 Control opens automatically when the user logs in. Registered as a macOS
    /// login item via SMAppService. This is a snapshot of the OS state —
    /// `SMAppService.mainApp.status == .enabled` — refreshed on init, after each
    /// `setLaunchAtLogin(_:)`, and via `refreshLaunchAtLoginStatus()` (e.g. when the app
    /// becomes active again after the user approves the item in System Settings).
    @Published var launchAtLogin: Bool
    /// A user-visible message describing why a launch-at-login change failed, or nil. Cleared
    /// on the next attempt / refresh.
    @Published var launchAtLoginError: String?
    /// Whether a normal DS4 Control quit should also stop ds4-server. The existing behavior
    /// remains the default: leave the loaded model available in the background.
    @Published private(set) var stopServerOnQuit: Bool
    /// False until the user answers the one-time quit prompt or changes the Settings toggle.
    /// Kept separate from `stopServerOnQuit` because false is both the default and a real choice.
    private(set) var quitBehaviorChosen: Bool
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

    init(defaults: UserDefaults = .standard, ramGiB: Double = systemRamGiB()) {
        self.d = defaults
        port = d.object(forKey: "port") as? Int ?? 8000
        host = d.string(forKey: "host") ?? Self.defaultHost
        let storedCtxOverride = d.integer(forKey: "ctxOverride")
        let p = d.integer(forKey: "power"); power = p > 0 ? p : nil
        let sessions = d.integer(forKey: "concurrentSessions")
        concurrentSessions = sessions >= 1 ? min(sessions, maxConcurrentSessions) : 1
        kvDiskCache = d.object(forKey: "kvDiskCache") as? Bool ?? true  // default on
        let requestedThinkingMode: ThinkingMode
        if let storedMode = d.string(forKey: "thinkingMode").flatMap(ThinkingMode.init(rawValue:)) {
            requestedThinkingMode = storedMode
        } else if d.object(forKey: "thinkMaxChat") != nil {
            requestedThinkingMode = d.bool(forKey: "thinkMaxChat") ? .max : .off
        } else {
            requestedThinkingMode = .standard
        }
        let resolvedThinkingMode =
            requestedThinkingMode == .max && !supportsMaxThink(ramGiB: ramGiB)
            ? .standard : requestedThinkingMode
        let resetMaxCreatedContext =
            resolvedThinkingMode != requestedThinkingMode
            && storedCtxOverride == thinkMaxMinCtx
        ctxOverride = resetMaxCreatedContext ? 0 : storedCtxOverride
        thinkingMode = resolvedThinkingMode
        if resolvedThinkingMode != requestedThinkingMode {
            d.set(resolvedThinkingMode.rawValue, forKey: "thinkingMode")
            if resetMaxCreatedContext { d.set(0, forKey: "ctxOverride") }
        }
        highPerformanceDownload = d.bool(forKey: "highPerformanceDownload")  // default off
        launchAtLogin = SMAppService.mainApp.status == .enabled  // OS is the source of truth
        let storedStopServerOnQuit = d.bool(forKey: "stopServerOnQuit")
        let storedQuitBehaviorChosen = d.bool(forKey: "quitBehaviorChosen")
        stopServerOnQuit = storedStopServerOnQuit  // default: keep server running
        quitBehaviorChosen = storedQuitBehaviorChosen || storedStopServerOnQuit
        if storedStopServerOnQuit && !storedQuitBehaviorChosen {
            // Preserve the invariant if the stop preference was written independently (for
            // example by a prerelease build): an explicit true preference is already a choice.
            d.set(true, forKey: "quitBehaviorChosen")
        }
        legacyWeightsPromptDismissed = d.bool(forKey: "legacyWeightsPromptDismissed0731")  // default false
        let stored = d.string(forKey: "selectedVariant").flatMap(Variant.init(rawValue:))
        selectedVariant = stored ?? (ramGiB >= 512 ? .pro : .flash)  // default Pro on ≥512 GiB
        let storedQuant = d.string(forKey: "selectedFlashQuant").flatMap(FlashQuant.init(rawValue:))
        selectedFlashQuant = storedQuant ?? defaultFlashQuant(ramGiB: ramGiB)  // default q2-q4-imatrix
    }

    func effectiveCtx(ramGiB: Double) -> Int {
        ctxOverride > 0
            ? min(ctxOverride, selectedVariant.ctxCeiling)
            : defaultCtx(ramGiB: ramGiB, variant: selectedVariant, flashQuant: selectedFlashQuant)
    }

    /// Set the chat's thinking level. Max is unavailable below 128 GiB and otherwise needs
    /// context ≥ 393,216. Rejections leave the current mode unchanged.
    func requestThinkingMode(
        _ mode: ThinkingMode, currentCtx: Int, ramGiB: Double = systemRamGiB()
    ) -> ThinkingModeGate {
        if mode == .max && !supportsMaxThink(ramGiB: ramGiB) { return .unavailable }
        if mode == .max && !thinkMax(ctx: currentCtx) { return .needsCtxBump }
        thinkingMode = mode
        return .applied
    }

    /// The user confirmed the context bump: pin the override to ds4's Max Think floor and
    /// enable `.max`. Returns false when the machine tier cannot safely offer Max Think.
    /// Restarting a running server is the caller's job.
    @discardableResult
    func applyMaxThinkCtxBump(ramGiB: Double = systemRamGiB()) -> Bool {
        guard supportsMaxThink(ramGiB: ramGiB) else { return false }
        ctxOverride = thinkMaxMinCtx
        thinkingMode = .max
        return true
    }

    func normalizeHostForLaunch() -> String {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
        host = normalized.isEmpty ? Self.defaultHost : normalized
        return host
    }

    /// Record either quit policy as an explicit choice. Both the first-quit alert and the
    /// Settings toggle use this single path so the prompt can never reappear after a choice.
    func setStopServerOnQuit(_ enabled: Bool) {
        stopServerOnQuit = enabled
        quitBehaviorChosen = true
        d.set(enabled, forKey: "stopServerOnQuit")
        d.set(true, forKey: "quitBehaviorChosen")
    }

    /// Turn automatic launch-at-login on or off. Registers/unregisters this app as a macOS
    /// login item via SMAppService (the modern, notarization-friendly replacement for the
    /// deprecated SMLoginItemSetEnabled). The toggle always reflects the OS's actual state:
    /// if registration needs approval (.requiresApproval) we open the Login Items pane and
    /// keep the toggle off until it takes effect; if the OS rejects the change (e.g. running
    /// un-bundled from the build directory, where there's no real .app to register) the
    /// toggle reverts to off so the UI never lies.
    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Reflect the OS's actual state below and surface the failure to the user (e.g.
            // running un-bundled from the build directory, where there's no real .app to
            // register).
            launchAtLoginError = error.localizedDescription
        }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if enabled && status == .requiresApproval {
            // Registration needs the user's approval — surface the Login Items pane so they
            // can approve, and keep the toggle off until it actually takes effect.
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    /// Re-read the OS login-item state into `launchAtLogin`. Call after the user may have
    /// changed it externally — e.g. approving the item in System Settings, which flips
    /// `SMAppService.mainApp.status` to `.enabled` while this snapshot is still stale.
    func refreshLaunchAtLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
