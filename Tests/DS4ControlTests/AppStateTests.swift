import XCTest
@testable import DS4Control

@MainActor
final class AppStateTests: XCTestCase {
    func testEffectiveCtxFallsBackToDefault() {
        let d = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let app = AppState(defaults: d)
        app.selectedVariant = .flash
        app.ctxOverride = 0
        XCTAssertEqual(
            app.effectiveCtx(ramGiB: 128),
            defaultCtx(ramGiB: 128, variant: .flash, flashQuant: app.selectedFlashQuant))
        app.ctxOverride = 50_000
        XCTAssertEqual(app.effectiveCtx(ramGiB: 128), 50_000)
    }
    func testPersistence() {
        let name = "test.\(UUID().uuidString)"
        let d1 = UserDefaults(suiteName: name)!
        let a1 = AppState(defaults: d1)
        a1.port = 9001; a1.host = "0.0.0.0"; a1.ctxOverride = 250_000; a1.highPerformanceDownload = true
        let d2 = UserDefaults(suiteName: name)!
        let a2 = AppState(defaults: d2)
        XCTAssertEqual(a2.port, 9001); XCTAssertEqual(a2.ctxOverride, 250_000)
        XCTAssertEqual(a2.host, "0.0.0.0")
        XCTAssertTrue(a2.highPerformanceDownload)
    }
    func testHostDefaultsToLocalhost() {
        let name = "test.\(UUID().uuidString)"
        let app = AppState(defaults: UserDefaults(suiteName: name)!)
        XCTAssertEqual(app.host, AppState.defaultHost)
    }

    func testNormalizeHostForLaunchTrimsWhitespace() {
        let name = "test.\(UUID().uuidString)"
        let app = AppState(defaults: UserDefaults(suiteName: name)!)
        app.host = " \n0.0.0.0\t "
        XCTAssertEqual(app.normalizeHostForLaunch(), "0.0.0.0")
        XCTAssertEqual(app.host, "0.0.0.0")
        XCTAssertEqual(AppState(defaults: UserDefaults(suiteName: name)!).host, "0.0.0.0")
    }

    func testNormalizeHostForLaunchFallsBackForWhitespaceOnly() {
        let name = "test.\(UUID().uuidString)"
        let app = AppState(defaults: UserDefaults(suiteName: name)!)
        app.host = " \n\t "
        XCTAssertEqual(app.normalizeHostForLaunch(), AppState.defaultHost)
        XCTAssertEqual(app.host, AppState.defaultHost)
        XCTAssertEqual(AppState(defaults: UserDefaults(suiteName: name)!).host, AppState.defaultHost)
    }

    func testKvDiskCacheDefaultsOnAndPersists() {
        let name = "test.\(UUID().uuidString)"
        let a1 = AppState(defaults: UserDefaults(suiteName: name)!)
        XCTAssertTrue(a1.kvDiskCache)  // default on
        a1.kvDiskCache = false
        let a2 = AppState(defaults: UserDefaults(suiteName: name)!)
        XCTAssertFalse(a2.kvDiskCache)  // persisted
    }
}
