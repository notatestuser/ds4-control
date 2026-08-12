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

@MainActor
enum RestartRejectionAlert {
    static func show(
        _ feasibility: Feasibility,
        contextSentence: String,
        restartAnyway: () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch feasibility {
        case let .wiredLimitTooLow(requiredMB, advisoryMB):
            alert.messageText = "Metal wired limit too low"
            alert.informativeText =
                "\(contextSentence) The requested setup needs ~\(roundedUpGiB(fromMB: requiredMB)) GiB of GPU-wired memory. "
                + "Raise the limit, then try again:\n\nsudo sysctl iogpu.wired_limit_mb=\(advisoryMB)\n\n"
                + "Or explicitly restart anyway."
            alert.addButton(withTitle: "Copy Fix Command")
            alert.addButton(withTitle: "Restart Anyway")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[1].keyEquivalent = ""
            alert.buttons[2].keyEquivalent = "\r"
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    "sudo sysctl iogpu.wired_limit_mb=\(advisoryMB)", forType: .string)
            case .alertSecondButtonReturn:
                restartAnyway()
            default:
                break
            }
        case let .blocked(reason):
            alert.messageText = "These settings cannot run on this Mac"
            alert.informativeText = "\(contextSentence) \(reason)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .standard:
            break
        }
    }
}

@MainActor
enum ThinkingModePrompt {
    /// NSAlert (Settings and Chat are real windows, already promoted to .regular by
    /// WindowChrome). On confirm: pin the context to 393,216 + enable Max — and, when a
    /// server is running, restart it with the new context (same parameters as Settings →
    /// Apply & Restart Server).
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
        guard serverRunning else { app.applyMaxThinkCtxBump(); return }
        handleRestartResult(
            restartWithMaxThink(app: app, supervisor: supervisor),
            app: app, supervisor: supervisor)
    }

    /// Keep the preference change transactional with the restart gate: chat must not
    /// send Max Think to the old, smaller-context server after a rejected restart.
    @discardableResult
    static func restartWithMaxThink(
        app: AppState, supervisor: SupervisorService,
        overrideWiredLimitGate: Bool = false
    ) -> RestartResult {
        let result = supervisor.restart(
            variant: app.selectedVariant, flashQuant: app.selectedFlashQuant,
            ctx: thinkMaxMinCtx,
            host: app.normalizeHostForLaunch(), port: app.port, power: app.power,
            sessions: app.concurrentSessions,
            kvDiskDir: app.kvDiskCache ? supervisor.kvDiskCacheURL : nil,
            overrideWiredLimitGate: overrideWiredLimitGate)
        if result == .accepted { app.applyMaxThinkCtxBump() }
        return result
    }

    private static func handleRestartResult(
        _ result: RestartResult, app: AppState, supervisor: SupervisorService
    ) {
        switch result {
        case .accepted:
            break
        case let .rejected(feasibility):
            RestartRejectionAlert.show(
                feasibility,
                contextSentence:
                    "The current server is still running at its existing context. Max Think remains disabled."
            ) {
                handleRestartResult(
                    restartWithMaxThink(
                        app: app, supervisor: supervisor,
                        overrideWiredLimitGate: true),
                    app: app, supervisor: supervisor)
            }
        case .ignored:
            // The server may have stopped while the confirmation was open. The setting
            // is still valid and will apply on the next Start.
            if supervisor.state != .ready && supervisor.state != .starting {
                app.applyMaxThinkCtxBump()
            }
        }
    }

}
