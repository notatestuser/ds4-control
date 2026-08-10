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
    }

    /// Both launch paths (the Start button and the error-state Retry) must pass the full option
    /// set. They used to be two copies of the same `supervisor.start(...)` call, which this test
    /// guarded by counting; they now share one `startServer()`, so the invariant is stronger —
    /// assert there is exactly ONE call site, reached from both buttons.
    func testModelRowViewNormalizesBeforeStart() throws {
        let modelRow = try source("Sources/DS4Control/Views/ModelRowView.swift")

        XCTAssertTrue(modelRow.contains("let host = app.normalizeHostForLaunch()"))
        XCTAssertTrue(modelRow.contains("host: host"))
        XCTAssertEqual(
            modelRow.components(separatedBy: "supervisor.start(").count - 1, 1,
            "one launch call site, so Start and Retry can't drift apart")
        XCTAssertEqual(modelRow.components(separatedBy: "kvDiskDir:").count - 1, 1)
        XCTAssertEqual(modelRow.components(separatedBy: "dsparkSupport:").count - 1, 1)
        // definition + the Retry branch + the Start button
        XCTAssertEqual(modelRow.components(separatedBy: "startServer").count - 1, 3)
    }
}
