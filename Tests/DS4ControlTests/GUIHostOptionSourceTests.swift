import XCTest

final class GUIHostOptionSourceTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testSettingsViewBindsHostAndNormalizesBeforeRestart() throws {
        let settings = try source("Sources/DS4Control/Views/SettingsView.swift")

        XCTAssertTrue(settings.contains("TextField(\"\", text: $app.host)"))
        XCTAssertTrue(settings.contains("Chat and agents on this Mac always use 127.0.0.1."))
        XCTAssertTrue(settings.contains("Enter 0.0.0.0 to let other devices connect."))
        let bindHost = try XCTUnwrap(settings.range(of: "Text(\"Bind host\")"))
        let bindHelp = try XCTUnwrap(settings.range(of: "The address ds4-server listens on."))
        let sessions = try XCTUnwrap(settings.range(of: "Text(\"Concurrent sessions\")"))
        let gpuPower = try XCTUnwrap(settings.range(of: "Text(\"GPU power duty\")"))
        XCTAssertLessThan(bindHost.lowerBound, bindHelp.lowerBound)
        XCTAssertLessThan(bindHelp.lowerBound, gpuPower.lowerBound)
        XCTAssertLessThan(sessions.lowerBound, gpuPower.lowerBound)  // slider sits above GPU power duty
        XCTAssertTrue(settings.contains("let host = app.normalizeHostForLaunch()"))
        XCTAssertTrue(settings.contains("supervisor.restart("))
        XCTAssertTrue(settings.contains("host: host"))
        XCTAssertTrue(settings.contains("if case let .rejected(feasibility) = result"))
        XCTAssertTrue(settings.contains("Restart Anyway"))
        XCTAssertTrue(settings.contains("openWindow(id: \"wiredhelp\")"))
        XCTAssertTrue(settings.contains("overrideWiredLimitGate: overrideWiredLimitGate"))
        XCTAssertTrue(settings.contains("min(Int(digits) ?? app.selectedVariant.ctxCeiling"))
    }

    func testModelRowViewNormalizesBeforeStart() throws {
        let modelRow = try source("Sources/DS4Control/Views/ModelRowView.swift")

        XCTAssertTrue(modelRow.contains("let host = app.normalizeHostForLaunch()"))
        XCTAssertTrue(modelRow.contains("supervisor.start("))
        XCTAssertTrue(modelRow.contains("host: host"))
        // Both start paths (Retry and Start) route through one startServer() helper now,
        // so the kvDiskDir argument appears exactly once.
        XCTAssertEqual(modelRow.components(separatedBy: "kvDiskDir:").count - 1, 1)
    }

    func testWiredLimitHelpSuppressesCommandsForBlockedConfiguration() throws {
        let help = try source("Sources/DS4Control/Views/WiredLimitHelpView.swift")

        let blockedBranch = try XCTUnwrap(help.range(of: "if let blockedReason"))
        let commandBranch = try XCTUnwrap(help.range(of: "wiredLimitInstructions"))
        XCTAssertLessThan(blockedBranch.lowerBound, commandBranch.lowerBound)
        XCTAssertTrue(help.contains("guard case let .blocked(reason) = result"))
        XCTAssertTrue(help.contains("A Metal wired-limit change cannot make this configuration fit."))
    }
}
