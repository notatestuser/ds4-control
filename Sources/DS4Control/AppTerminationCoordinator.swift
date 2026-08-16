import AppKit

enum QuitBehaviorChoice: Equatable {
    case alwaysStop
    case keepRunning
    case cancel
}

/// Narrow lifecycle interface so quit policy can be tested without launching a real server.
@MainActor
protocol ServerQuitSupervising: AnyObject {
    var state: ServerState { get }
    func stopForTermination(completion: ((Bool) -> Void)?)
}

extension SupervisorService: ServerQuitSupervising {}

/// Owns the normal-quit decision while AppDelegate remains a thin AppKit bridge.
@MainActor
final class AppTerminationCoordinator {
    typealias PresentChoice = () -> QuitBehaviorChoice
    typealias PresentStopFailure = () -> Void
    typealias Reply = (Bool) -> Void

    private let app: AppState
    private let supervisor: any ServerQuitSupervising
    private let presentChoice: PresentChoice
    private let presentStopFailure: PresentStopFailure
    private var waitingForServerStop = false

    private static let quitBehaviorAlertTitle = "DS4 Control Quit Behavior"

    init(
        app: AppState,
        supervisor: any ServerQuitSupervising,
        presentChoice: @escaping PresentChoice = { AppTerminationCoordinator.presentQuitBehaviorAlert() },
        presentStopFailure: @escaping PresentStopFailure = {
            AppTerminationCoordinator.presentServerStopFailureAlert()
        }
    ) {
        self.app = app
        self.supervisor = supervisor
        self.presentChoice = presentChoice
        self.presentStopFailure = presentStopFailure
    }

    func applicationShouldTerminate(reply: @escaping Reply) -> NSApplication.TerminateReply {
        // AppKit has one outstanding terminate-later handshake. A repeated Quit while the
        // server drains must join it rather than prompting or signalling the server again.
        if waitingForServerStop { return .terminateLater }

        switch supervisor.state {
        case .starting, .ready:
            if !app.quitBehaviorChosen {
                switch presentChoice() {
                case .alwaysStop:
                    app.setStopServerOnQuit(true)
                case .keepRunning:
                    app.setStopServerOnQuit(false)
                case .cancel:
                    return .terminateCancel
                }
            }
            return app.stopServerOnQuit ? stopThenTerminate(reply: reply) : .terminateNow

        case .stopping:
            // The user already asked for Stop; keep the app alive long enough to honor it.
            return stopThenTerminate(reply: reply)

        case .idle, .downloading, .error:
            // An irrelevant quit must not consume the one-time server-behavior choice.
            return .terminateNow
        }
    }

    private func stopThenTerminate(reply: @escaping Reply) -> NSApplication.TerminateReply {
        waitingForServerStop = true
        supervisor.stopForTermination { [weak self] stopped in
            // Some runners and an attached server with no remaining listener can complete
            // synchronously. Defer the AppKit reply until after `.terminateLater` is returned.
            DispatchQueue.main.async {
                guard let self, self.waitingForServerStop else { return }
                self.waitingForServerStop = false
                if !stopped { self.presentStopFailure() }
                reply(stopped)
            }
        }
        return .terminateLater
    }

    private static func presentQuitBehaviorAlert() -> QuitBehaviorChoice {
        let alert = makeQuitBehaviorAlert()
        WindowChrome.windowOpened(title: quitBehaviorAlertTitle)
        let response = alert.runModal()
        WindowChrome.windowClosed()
        return quitBehaviorChoice(for: response)
    }

    /// Kept separate from presentation so button order and keyboard defaults are testable
    /// without opening an application-modal alert in the test process.
    static func makeQuitBehaviorAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Stop ds4-server when DS4 Control quits?"
        alert.informativeText =
            "Keeping it running leaves the model loaded and available to chat, coding agents, "
            + "and other clients. You can change this later in Settings."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Always Stop")
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = "\r"  // Return accepts the recommended default.
        alert.buttons[1].keyEquivalent = ""
        alert.buttons[2].keyEquivalent = "\u{1b}"  // Escape keeps DS4 Control open.
        alert.window.title = quitBehaviorAlertTitle
        return alert
    }

    static func quitBehaviorChoice(for response: NSApplication.ModalResponse) -> QuitBehaviorChoice {
        switch response {
        case .alertFirstButtonReturn: return .alwaysStop
        case .alertSecondButtonReturn: return .keepRunning
        default: return .cancel
        }
    }

    private static func presentServerStopFailureAlert() {
        let alert = NSAlert()
        alert.messageText = "ds4-server could not be stopped"
        alert.informativeText =
            "DS4 Control stayed open because “Always Stop” is enabled. Try stopping the server again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        let title = "DS4 Control Stop Failure"
        alert.window.title = title
        WindowChrome.windowOpened(title: title)
        alert.runModal()
        WindowChrome.windowClosed()
    }
}
