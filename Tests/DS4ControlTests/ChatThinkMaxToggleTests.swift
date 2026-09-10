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

    func testThinkMaxPatchRemapsOfficialMaxPrefix() throws {
        let patch = try source("patches/ds4-think-max.patch")
        XCTAssertTrue(patch.contains("DS4_REASONING_EFFORT_MAX_PREFIX"))
        XCTAssertTrue(patch.contains("Beyond maximum — exhaustive, relentless, and uncompromising."))
        XCTAssertTrue(patch.contains("-    \"Reasoning Effort: Absolute maximum"))

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ds4URL = tmp.appendingPathComponent("ds4.c")
        FileManager.default.createFile(atPath: ds4URL.path, contents: nil)
        let showOut = try FileHandle(forWritingTo: ds4URL)
        let show = Process()
        show.currentDirectoryURL = root
        show.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        show.arguments = ["-C", "external/ds4", "show", "HEAD:ds4.c"]
        show.standardOutput = showOut
        let showErr = Pipe()
        show.standardError = showErr
        try show.run()
        show.waitUntilExit()
        try showOut.close()
        XCTAssertEqual(
            show.terminationStatus, 0,
            String(data: showErr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")

        let apply = Process()
        apply.currentDirectoryURL = tmp
        apply.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        apply.arguments = ["apply", root.appendingPathComponent("patches/ds4-think-max.patch").path]
        let applyErr = Pipe()
        apply.standardError = applyErr
        try apply.run()
        apply.waitUntilExit()
        XCTAssertEqual(
            apply.terminationStatus, 0,
            String(data: applyErr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")

        let patched = try String(contentsOf: tmp.appendingPathComponent("ds4.c"), encoding: .utf8)
        let start = try XCTUnwrap(patched.range(of: "static const char DS4_REASONING_EFFORT_MAX_PREFIX[]"))
        let end = try XCTUnwrap(patched.range(of: ";", range: start.upperBound..<patched.endIndex))
        let block = patched[start.lowerBound..<end.upperBound]
        XCTAssertTrue(block.contains("Beyond maximum — exhaustive, relentless, and uncompromising."))
        XCTAssertFalse(block.contains("Absolute maximum"))
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

    func testPopupHasServerSpeedCard() throws {
        let popup = try source("Sources/DS4Control/Views/PopupView.swift")
        XCTAssertTrue(popup.contains(#""Server", icon: "speedometer""#))
        XCTAssertTrue(popup.contains("serverSpeedHistory"))
        XCTAssertTrue(popup.contains("serverSpeedValue"))
        XCTAssertTrue(popup.contains("serverSpeedSubtitle"))
    }
}
