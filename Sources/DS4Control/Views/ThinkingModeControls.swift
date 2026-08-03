import AppKit
import SwiftUI

/// The shared Thinking: segmented picker (Instant / Standard / Max Think), used by Settings and
/// the chat status bar. Selecting Max Think below ds4's 393,216-context floor does NOT apply
/// the mode — ThinkingModePrompt first asks whether to bump the context (and restart, when a
/// server is running). Cancelling leaves the mode untouched.
struct ThinkingModePicker: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var supervisor: SupervisorService
    private let ram = systemRamGiB()

    var body: some View {
        Picker("Thinking:", selection: binding) {
            ForEach(ThinkingMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var serverRunning: Bool { supervisor.state == .ready || supervisor.state == .starting }

    private var binding: Binding<ThinkingMode> {
        Binding(
            get: { app.thinkingMode },
            set: { mode in
                let ctx = serverRunning ? supervisor.ctx : app.effectiveCtx(ramGiB: ram)
                guard app.requestThinkingMode(mode, currentCtx: ctx) == .needsCtxBump else { return }
                ThinkingModePrompt.confirmAndApply(serverRunning: serverRunning, app: app, supervisor: supervisor)
            }
        )
    }
}

enum ThinkingModePrompt {
    /// NSAlert (Settings and Chat are real windows, already promoted to .regular by
    /// WindowChrome). On confirm: pin the context to 393,216 + enable Max — and, when a
    /// server is running, restart it with the new context (same parameters as Settings →
    /// Apply & Restart Server).
    @MainActor
    static func confirmAndApply(serverRunning: Bool, app: AppState, supervisor: SupervisorService) {
        let alert = NSAlert()
        alert.messageText = "Max Think requires a context of at least 393,216."
        alert.informativeText =
            serverRunning
            ? "Set the context to 393,216, enable Max Think, and restart the server now? "
                + "The model will reload, with brief downtime."
            : "Set the context to 393,216 and enable Max Think?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: serverRunning ? "Set Context & Restart" : "Set Context & Enable")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        app.applyMaxThinkCtxBump()
        guard serverRunning else { return }
        supervisor.restart(
            variant: app.selectedVariant, flashQuant: app.selectedFlashQuant,
            ctx: app.effectiveCtx(ramGiB: systemRamGiB()),
            host: app.normalizeHostForLaunch(), port: app.port, power: app.power,
            sessions: app.concurrentSessions,
            kvDiskDir: app.kvDiskCache ? supervisor.kvDiskCacheURL : nil)
    }
}
