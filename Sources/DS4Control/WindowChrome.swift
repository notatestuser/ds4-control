import AppKit

/// A menu-bar-only (`.accessory`/LSUIElement) app owns no menu bar and doesn't normally
/// foreground its windows, so while one is open the text fields won't take focus (no key
/// window) and the auto-hidden menu bar won't reveal on a top-edge hover. While any
/// chat/settings window is open, become a `.regular` app and make that window key + front;
/// revert to `.accessory` when the last one closes (so it stays out of the Dock).
@MainActor
enum WindowChrome {
    private static var openCount = 0

    /// Call from a window's `.onAppear` (the window exists by then). Sets `.regular`,
    /// foregrounds the app, and makes the named window key — in that order, one path,
    /// to avoid the policy/activation race that left the window non-key.
    static func windowOpened(title: String) {
        openCount += 1
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let window = NSApplication.shared.windows.first(where: { $0.title == title }) {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }

    static func windowClosed() {
        openCount = max(0, openCount - 1)
        guard openCount == 0 else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
