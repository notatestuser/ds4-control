import SwiftUI

@main
struct DS4ControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var app: AppState
    @StateObject private var metrics = MetricsManager()
    @StateObject private var supervisor: SupervisorService
    @StateObject private var chat: ChatViewModel
    @State private var menuBarStartup = MenuBarStartupCoordinator()

    init() {
        MarkdownText.runResourceSelfTestIfRequested()  // headless bundle-resolution check (env-gated)
        HFDownloader.runSelfTestIfRequested()  // headless native-download check (env-gated)
        let app = AppState()
        _app = StateObject(wrappedValue: app)  // same instance the chat closures read, so the UI's toggles reach it
        let supervisor = SupervisorService(
            ds4Dir: bundledDS4Dir(), runner: RealProcessRunner(),
            ggufBaseURL: ds4AppSupportDir().appendingPathComponent("gguf", isDirectory: true))
        _supervisor = StateObject(wrappedValue: supervisor)
        let service = ChatService()
        _chat = StateObject(
            wrappedValue: ChatViewModel(
                model: app.selectedVariant.modelId,
                port: { [weak supervisor] in supervisor?.port ?? app.port },
                streamProvider: { port, model, messages in
                    service.stream(port: port, model: model, messages: messages, mode: app.thinkingMode)
                }
            )
        )
        appDelegate.configure(app: app, supervisor: supervisor)
    }

    var body: some Scene {
        MenuBarExtra {
            PopupView()
                .environmentObject(app).environmentObject(metrics).environmentObject(supervisor)
                .onAppear { startMenuBarServicesIfNeeded() }
        } label: {
            MenuBarLabelView(state: supervisor.state)
        }
        .menuBarExtraStyle(.window)

        Window("DS4 Control Settings", id: "settings") {
            SettingsView().environmentObject(app).environmentObject(supervisor)
        }
        .windowResizability(.contentSize)

        Window("DS4 Metal Wired Limit Help", id: "wiredhelp") {
            WiredLimitHelpView().environmentObject(app)
        }
        .windowResizability(.contentSize)

        Window("DS4 Chat", id: "chat") {
            ChatView(viewModel: chat).environmentObject(app).environmentObject(supervisor)
        }
    }

    private func startMenuBarServicesIfNeeded() {
        guard !menuBarStartup.started else { return }
        menuBarStartup.started = true
        DispatchQueue.main.async {
            metrics.start()
            supervisor.resumeRunningServerIfAny(port: app.port)
            supervisor.resumeInFlightDownloadIfAny(
                variant: app.selectedVariant, flashQuant: app.selectedFlashQuant,
                highPerformance: app.highPerformanceDownload)
        }
    }
}

private final class MenuBarStartupCoordinator {
    var started = false
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationCoordinator: AppTerminationCoordinator?

    func configure(app: AppState, supervisor: SupervisorService) {
        terminationCoordinator = AppTerminationCoordinator(app: app, supervisor: supervisor)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)  // menu-bar only (LSUIElement)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let terminationCoordinator else {
            NSLog("DS4 Control termination coordination is unavailable; terminating immediately")
            return .terminateNow
        }
        return terminationCoordinator.applicationShouldTerminate { shouldTerminate in
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
    }
}
