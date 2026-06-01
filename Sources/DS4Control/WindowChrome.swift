import AppKit

/// A menu-bar-only (`.accessory`/LSUIElement) app owns no menu bar, so while one of its
/// windows is frontmost the system's auto-hidden menu bar won't reveal on a top-edge
/// hover. Switch to `.regular` while any chat/settings window is open — the app then owns
/// a real menu bar (and the window behaves like a normal app window) — and back to
/// `.accessory` when the last one closes, so it stays out of the Dock the rest of the time.
@MainActor
enum WindowChrome {
    private static var openCount = 0

    static func windowOpened() {
        openCount += 1
        guard openCount == 1 else { return }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    static func windowClosed() {
        openCount = max(0, openCount - 1)
        guard openCount == 0 else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
