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

    func testLegacyWeightsPromptDismissedPersists() {
        let name = "test.\(UUID().uuidString)"
        let a1 = AppState(defaults: UserDefaults(suiteName: name)!)
        XCTAssertFalse(a1.legacyWeightsPromptDismissed)  // default false → prompt shows
        a1.legacyWeightsPromptDismissed = true
        XCTAssertTrue(AppState(defaults: UserDefaults(suiteName: name)!).legacyWeightsPromptDismissed)
    }

    func testThinkingModeLabels() {
        XCTAssertEqual(ThinkingMode.allCases.map(\.label), ["Instant", "Standard", "Max Think"])
    }

    func testThinkingModePersists() {
        let name = "test.\(UUID().uuidString)"
        let a1 = AppState(defaults: UserDefaults(suiteName: name)!)
        XCTAssertEqual(a1.thinkingMode, .standard)  // default for a fresh install
        a1.thinkingMode = .max
        XCTAssertEqual(AppState(defaults: UserDefaults(suiteName: name)!).thinkingMode, .max)
    }

    func testThinkingModeMigratesLegacyBool() {
        let on = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        on.set(true, forKey: "thinkMaxChat")  // legacy key, no thinkingMode key
        XCTAssertEqual(AppState(defaults: on).thinkingMode, .max)
        let off = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        off.set(false, forKey: "thinkMaxChat")
        XCTAssertEqual(AppState(defaults: off).thinkingMode, .off)
    }

    func testThinkingModeGateAndCtxBump() {
        let app = AppState(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        // Max below the 393,216 floor: gated, mode unchanged.
        XCTAssertEqual(app.requestThinkingMode(.max, currentCtx: 131_072), .needsCtxBump)
        XCTAssertEqual(app.thinkingMode, .standard)  // unchanged from the fresh default
        // Standard needs no bump at any context.
        XCTAssertEqual(app.requestThinkingMode(.standard, currentCtx: 131_072), .applied)
        XCTAssertEqual(app.thinkingMode, .standard)
        // Confirming the bump sets the override and enables Max.
        app.applyMaxThinkCtxBump()
        XCTAssertEqual(app.ctxOverride, 393_216)
        XCTAssertEqual(app.thinkingMode, .max)
        // Max at the floor applies directly.
        let app2 = AppState(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        XCTAssertEqual(app2.requestThinkingMode(.max, currentCtx: 393_216), .applied)
        XCTAssertEqual(app2.thinkingMode, .max)
    }
}
