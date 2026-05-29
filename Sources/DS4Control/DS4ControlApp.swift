import SwiftUI

@main
struct DS4ControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var app = AppState()
    @StateObject private var metrics = MetricsManager()
    @StateObject private var supervisor: SupervisorService

    init() {
        let app = AppState()
        let dir = URL(fileURLWithPath: app.ds4Dir.isEmpty ? FileManager.default.currentDirectoryPath : app.ds4Dir)
        _supervisor = StateObject(wrappedValue: SupervisorService(ds4Dir: dir, runner: RealProcessRunner()))
    }

    var body: some Scene {
        MenuBarExtra {
            PopupView()
                .environmentObject(app).environmentObject(metrics).environmentObject(supervisor)
                .onAppear { metrics.start() }
        } label: {
            Image(systemName: iconName(for: supervisor.state))
                .renderingMode(.template)
                .foregroundStyle(iconColor(for: supervisor.state))
        }
        .menuBarExtraStyle(.window)

        Window("DS4 Control Settings", id: "settings") {
            SettingsView().environmentObject(app)
        }
        .windowResizability(.contentSize)
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
