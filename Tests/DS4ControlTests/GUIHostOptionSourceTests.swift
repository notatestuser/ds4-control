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
        XCTAssertTrue(settings.contains("The app's built-in chat and Terminal agent still connect through 127.0.0.1"))
        XCTAssertTrue(settings.contains("Use 0.0.0.0 to listen on all network interfaces."))
        let bindHost = try XCTUnwrap(settings.range(of: "Text(\"Bind host\")"))
        let bindHelp = try XCTUnwrap(settings.range(of: "Binds ds4-server to this address."))
        let gpuPower = try XCTUnwrap(settings.range(of: "Text(\"GPU power duty\")"))
        XCTAssertLessThan(bindHost.lowerBound, bindHelp.lowerBound)
        XCTAssertLessThan(bindHelp.lowerBound, gpuPower.lowerBound)
        XCTAssertTrue(settings.contains("let host = app.normalizeHostForLaunch()"))
        XCTAssertTrue(settings.contains("supervisor.restart("))
        XCTAssertTrue(settings.contains("host: host"))
    }

    func testModelRowViewNormalizesBeforeStart() throws {
        let modelRow = try source("Sources/DS4Control/Views/ModelRowView.swift")

        XCTAssertTrue(modelRow.contains("let host = app.normalizeHostForLaunch()"))
        XCTAssertTrue(modelRow.contains("supervisor.start("))
        XCTAssertTrue(modelRow.contains("host: host"))
        XCTAssertEqual(modelRow.components(separatedBy: "kvDiskDir:").count - 1, 2)
    }
}
