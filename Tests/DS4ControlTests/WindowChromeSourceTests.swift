import XCTest

/// Source-level regression guard: a one-shot `activate` on window open is silently dropped
/// often enough (post-launch `.accessory`→`.regular` transition in flight) to leave the
/// window visible but non-key — greyed controls — until the user reactivates the app by
/// hand. `windowOpened` must retry until the window is actually key (bounded).
final class WindowChromeSourceTests: XCTestCase {
    func testWindowOpenedRetriesActivationUntilKey() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/DS4Control/WindowChrome.swift"),
            encoding: .utf8)
        XCTAssertTrue(src.contains("attemptsLeft"), "activation must be a bounded retry, not one-shot")
        XCTAssertTrue(src.contains("window.isKeyWindow"), "the retry must stop on the key-window condition")
    }

    /// The decisive half of the fix: activation must ALSO be requested inside the menu-bar
    /// click (user-event context) before `openWindow` — deferred activates from onAppear are
    /// dropped outright for background-launched processes (dev runs via nohup).
    func testPopupActivatesWithinTheClickBeforeOpeningWindows() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/DS4Control/Views/PopupView.swift"),
            encoding: .utf8)
        for id in ["settings", "chat"] {
            let open = try XCTUnwrap(src.range(of: "openWindow(id: \"\(id)\")"))
            let activate = try XCTUnwrap(
                src.range(of: "WindowChrome.willOpenWindow()", range: src.startIndex..<open.lowerBound),
                "openWindow(id: \"\(id)\") must be preceded by WindowChrome.willOpenWindow()")
            XCTAssertLessThan(activate.lowerBound, open.lowerBound)
        }
    }
}
