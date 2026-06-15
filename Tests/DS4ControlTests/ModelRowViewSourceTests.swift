import XCTest

final class ModelRowViewSourceTests: XCTestCase {
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

    func testErrorRetryStartCarriesKvDiskCacheSetting() throws {
        let view = try source("Sources/DS4Control/Views/ModelRowView.swift")
        let errorCase = try XCTUnwrap(view.range(of: "case .error:"))
        let defaultCase = try XCTUnwrap(view.range(of: "default:", range: errorCase.upperBound..<view.endIndex))
        let errorBlock = view[errorCase.lowerBound..<defaultCase.lowerBound]

        XCTAssertTrue(
            errorBlock.contains("kvDiskDir: app.kvDiskCache ? supervisor.kvDiskCacheURL : nil"),
            "Retry from an error state must preserve the Disk KV cache setting when restarting.")
    }
}
