import XCTest

final class AppStartupDeferralTests: XCTestCase {
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

    func testMenuBarStartupWorkIsDeferredOutOfOnAppearUpdatePass() throws {
        let app = try source("Sources/DS4Control/DS4ControlApp.swift")

        XCTAssertTrue(app.contains("DispatchQueue.main.async"))
        XCTAssertTrue(app.contains("startMenuBarServicesIfNeeded()"))
        XCTAssertFalse(app.contains(".onAppear {\n                    metrics.start()"))
    }
}
