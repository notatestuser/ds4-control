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
        app.ctxOverride = Int.max
        XCTAssertEqual(app.effectiveCtx(ramGiB: 128), app.selectedVariant.ctxCeiling)
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
        let a1 = AppState(defaults: UserDefaults(suiteName: name)!, ramGiB: 128)
        XCTAssertEqual(a1.thinkingMode, .standard)  // default for a fresh install
        a1.thinkingMode = .max
        XCTAssertEqual(
            AppState(defaults: UserDefaults(suiteName: name)!, ramGiB: 128).thinkingMode,
            .max)
    }

    func testThinkingModeMigratesLegacyBool() {
        let on = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        on.set(true, forKey: "thinkMaxChat")  // legacy key, no thinkingMode key
        XCTAssertEqual(AppState(defaults: on, ramGiB: 128).thinkingMode, .max)
        let off = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        off.set(false, forKey: "thinkMaxChat")
        XCTAssertEqual(AppState(defaults: off, ramGiB: 96).thinkingMode, .off)
    }

    func testMaxThinkingModeDowngradesBelow128GiB() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        defaults.set(ThinkingMode.max.rawValue, forKey: "thinkingMode")
        defaults.set(thinkMaxMinCtx, forKey: "ctxOverride")

        let app = AppState(defaults: defaults, ramGiB: 96)

        XCTAssertEqual(app.thinkingMode, .standard)
        XCTAssertEqual(app.ctxOverride, 0)
        XCTAssertEqual(app.effectiveCtx(ramGiB: 96), 256_000)
        XCTAssertEqual(defaults.string(forKey: "thinkingMode"), ThinkingMode.standard.rawValue)
        XCTAssertEqual(defaults.integer(forKey: "ctxOverride"), 0)
    }

    func testThinkingModeGateAndCtxBump() {
        let lowMemoryApp = AppState(
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!, ramGiB: 96)
        XCTAssertEqual(
            lowMemoryApp.requestThinkingMode(.max, currentCtx: 393_216, ramGiB: 96),
            .unavailable)
        XCTAssertFalse(lowMemoryApp.applyMaxThinkCtxBump(ramGiB: 96))
        XCTAssertEqual(lowMemoryApp.thinkingMode, .standard)

        let app = AppState(
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!, ramGiB: 128)
        // Max below the 393,216 floor: gated, mode unchanged.
        XCTAssertEqual(
            app.requestThinkingMode(.max, currentCtx: 131_072, ramGiB: 128), .needsCtxBump)
        XCTAssertEqual(app.thinkingMode, .standard)  // unchanged from the fresh default
        // Standard needs no bump at any context.
        XCTAssertEqual(
            app.requestThinkingMode(.standard, currentCtx: 131_072, ramGiB: 128), .applied)
        XCTAssertEqual(app.thinkingMode, .standard)
        // Confirming the bump sets the override and enables Max.
        XCTAssertTrue(app.applyMaxThinkCtxBump(ramGiB: 128))
        XCTAssertEqual(app.ctxOverride, 393_216)
        XCTAssertEqual(app.thinkingMode, .max)
        // Max at the floor applies directly.
        let app2 = AppState(
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!, ramGiB: 128)
        XCTAssertEqual(
            app2.requestThinkingMode(.max, currentCtx: 393_216, ramGiB: 128), .applied)
        XCTAssertEqual(app2.thinkingMode, .max)
    }
}
