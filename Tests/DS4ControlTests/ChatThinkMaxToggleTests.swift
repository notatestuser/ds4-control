import XCTest

final class ChatThinkMaxToggleTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testChatStatusBarHasSharedMaxThinkToggle() throws {
        let chatView = try source("Sources/DS4Control/Views/ChatView.swift")
        let app = try source("Sources/DS4Control/DS4ControlApp.swift")

        XCTAssertTrue(chatView.contains("@EnvironmentObject var app: AppState"))
        XCTAssertTrue(chatView.contains(#"Toggle("Max Think", isOn: $app.thinkMaxChat)"#))
        XCTAssertTrue(app.contains("ChatView(viewModel: chat).environmentObject(app).environmentObject(supervisor)"))
    }

    func testSettingsChatSectionComesAfterApplyRestartSection() throws {
        let settings = try source("Sources/DS4Control/Views/SettingsView.swift")
        let applyIndex = try XCTUnwrap(settings.range(of: #"Button("Apply & Restart Server", action: restart)"#))
        let chatIndex = try XCTUnwrap(settings.range(of: #"Toggle("Enable Think Max in chat", isOn: $app.thinkMaxChat)"#))

        XCTAssertLessThan(applyIndex.lowerBound, chatIndex.lowerBound)
    }
}
