import XCTest

final class ChatThinkMaxToggleTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let root =
            testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testChatStatusBarHasSharedThinkingPicker() throws {
        let chatView = try source("Sources/DS4Control/Views/ChatView.swift")
        let app = try source("Sources/DS4Control/DS4ControlApp.swift")

        XCTAssertTrue(chatView.contains("@EnvironmentObject var app: AppState"))
        XCTAssertTrue(chatView.contains("ThinkingModePicker()"))
        XCTAssertTrue(app.contains("ChatView(viewModel: chat).environmentObject(app).environmentObject(supervisor)"))
    }

    func testSettingsChatSectionComesAfterApplyRestartSection() throws {
        let settings = try source("Sources/DS4Control/Views/SettingsView.swift")
        let applyIndex = try XCTUnwrap(settings.range(of: #"Button("Apply & Restart Server") { restart() }"#))
        let chatIndex = try XCTUnwrap(settings.range(of: "ThinkingModePicker()"))

        XCTAssertLessThan(applyIndex.lowerBound, chatIndex.lowerBound)
    }

    func testLowMemoryPickerOmitsMaxThinkAndPopupPortHasNoModeSuffix() throws {
        let thinking = try source("Sources/DS4Control/Views/ThinkingModeControls.swift")
        let popup = try source("Sources/DS4Control/Views/PopupView.swift")
        let settings = try source("Sources/DS4Control/Views/SettingsView.swift")

        XCTAssertTrue(
            thinking.contains(
                "supportsMaxThink(ramGiB: ram) ? ThinkingMode.allCases : [.off, .standard]"))
        XCTAssertFalse(popup.contains("· Think-Max"))
        XCTAssertFalse(popup.contains("thinkMaxActive"))
        XCTAssertTrue(settings.contains("if !supportsMaxThink(ramGiB: ram)"))
        XCTAssertTrue(settings.contains("Max Think requires at least 128 GiB unified memory."))
        XCTAssertTrue(settings.contains("Max Think is unavailable below 128 GiB unified memory."))
    }
}
