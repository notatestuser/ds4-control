import SwiftUI

@main
struct DS4ControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var app = AppState()
    @StateObject private var metrics = MetricsManager()
    @StateObject private var supervisor: SupervisorService
    @StateObject private var chat: ChatViewModel

    init() {
        let app = AppState()
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
                    service.stream(port: port, model: model, messages: messages)
                }
            )
        )
    }

    var body: some Scene {
        MenuBarExtra {
            PopupView()
                .environmentObject(app).environmentObject(metrics).environmentObject(supervisor)
                .onAppear {
                    metrics.start()
                    supervisor.resumeRunningServerIfAny(port: app.port)
                    supervisor.resumeInFlightDownloadIfAny(
                        variant: app.selectedVariant, flashQuant: app.selectedFlashQuant)
                }
        } label: {
            Image(systemName: iconName(for: supervisor.state))
                .renderingMode(.template)
                .foregroundStyle(iconColor(for: supervisor.state))
        }
        .menuBarExtraStyle(.window)

        Window("DS4 Control Settings", id: "settings") {
            SettingsView().environmentObject(app).environmentObject(supervisor)
        }
        .windowResizability(.contentSize)

        Window("DS4 Chat", id: "chat") {
            ChatView(viewModel: chat).environmentObject(supervisor)
        }
    }

    private func iconName(for s: ServerState) -> String {
        if case .error = s { return "exclamationmark.triangle.fill" }
        switch s {
        case .ready: return "bolt.fill";
        case .starting, .downloading: return "bolt.badge.clock";
        default: return "bolt.slash"
        }
    }
    private func iconColor(for s: ServerState) -> Color {
        switch s {
        case .ready: return .green;
        case .starting, .downloading: return .orange;
        case .error: return .red;
        default: return .secondary
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)  // menu-bar only (LSUIElement)
    }
}
