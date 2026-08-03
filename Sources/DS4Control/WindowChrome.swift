import AppKit

/// A menu-bar-only (`.accessory`/LSUIElement) app owns no menu bar and doesn't normally
/// foreground its windows, so while one is open the text fields won't take focus (no key
/// window) and the auto-hidden menu bar won't reveal on a top-edge hover. While any
/// chat/settings window is open, become a `.regular` app and make that window key + front;
/// revert to `.accessory` when the last one closes (so it stays out of the Dock).
@MainActor
enum WindowChrome {
    private static var openCount = 0

    /// Activate within the menu-bar click's user-event context, just before `openWindow`.
    /// A deferred activate (from the window's onAppear) can be dropped outright for a
    /// background-launched process (e.g. dev runs via nohup) — the window then opens
    /// visible but non-key, with greyed controls, no matter how often we retry; a request
    /// issued inside the click is honored.
    static func willOpenWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Call from a window's `.onAppear` (the window exists by then). Sets `.regular`,
    /// foregrounds the app, and makes the named window key. An `activate` request issued
    /// right after launch can be silently dropped while the `.accessory`→`.regular`
    /// transition is still in flight — leaving the window visible but never key (greyed
    /// controls) until the user reactivates the app by hand. So retry until the window is
    /// actually key, bounded to ~1 s.
    static func windowOpened(title: String) {
        openCount += 1
        NSApplication.shared.setActivationPolicy(.regular)
        activateAndFocus(title: title, attemptsLeft: 10)
    }

    private static func activateAndFocus(title: String, attemptsLeft: Int) {
        DispatchQueue.main.async {
            guard openCount > 0 else { return }  // the window was closed before a retry could fire
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let window = NSApplication.shared.windows.first(where: { $0.title == title }) {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                if NSApplication.shared.isActive && window.isKeyWindow { return }  // done
            }
            guard attemptsLeft > 1 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                activateAndFocus(title: title, attemptsLeft: attemptsLeft - 1)
            }
        }
    }

    static func windowClosed() {
        openCount = max(0, openCount - 1)
        guard openCount == 0 else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
