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
            defaultCtx(ramGiB: 128, selection: .flash(app.selectedFlashQuant)))
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

    func testQuitBehaviorDefaultsToUndecidedKeepRunningAndPersistsEitherChoice() {
        let keepName = "test.\(UUID().uuidString)"
        let keep = AppState(defaults: UserDefaults(suiteName: keepName)!)
        XCTAssertFalse(keep.stopServerOnQuit)
        XCTAssertFalse(keep.quitBehaviorChosen)
        keep.setStopServerOnQuit(false)
        let persistedKeep = AppState(defaults: UserDefaults(suiteName: keepName)!)
        XCTAssertFalse(persistedKeep.stopServerOnQuit)
        XCTAssertTrue(persistedKeep.quitBehaviorChosen)

        let stopName = "test.\(UUID().uuidString)"
        let stop = AppState(defaults: UserDefaults(suiteName: stopName)!)
        stop.setStopServerOnQuit(true)
        let persistedStop = AppState(defaults: UserDefaults(suiteName: stopName)!)
        XCTAssertTrue(persistedStop.stopServerOnQuit)
        XCTAssertTrue(persistedStop.quitBehaviorChosen)
    }

    func testStoredStopPreferenceCountsAsAQuitBehaviorChoice() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        defaults.set(true, forKey: "stopServerOnQuit")

        let app = AppState(defaults: defaults)

        XCTAssertTrue(app.stopServerOnQuit)
        XCTAssertTrue(app.quitBehaviorChosen)
        XCTAssertTrue(defaults.bool(forKey: "quitBehaviorChosen"))
    }

    func testLegacyStoragePromptUsesNewGenerationKeyAndPersists() {
        let name = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(true, forKey: "legacyWeightsPromptDismissed0731")
        let a1 = AppState(defaults: defaults)
        XCTAssertFalse(a1.legacyStoragePromptDismissed)  // the Pro migration must re-prompt
        a1.legacyStoragePromptDismissed = true
        XCTAssertTrue(AppState(defaults: defaults).legacyStoragePromptDismissed)
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

    /// Max Think is downgraded safely while each 96 GiB model keeps its own default context.
    func testMaxThinkingModeDowngradesBelow128GiB() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        defaults.set(ThinkingMode.max.rawValue, forKey: "thinkingMode")
        defaults.set(thinkMaxMinCtx, forKey: "ctxOverride")

        let app = AppState(defaults: defaults, ramGiB: 96)

        XCTAssertEqual(app.thinkingMode, .standard)
        XCTAssertEqual(app.ctxOverride, 0)
        // 96 GiB now defaults to V4.1 Flash (streaming → 32,768); the 0731 tier still
        // defaults to 256,000 there.
        XCTAssertEqual(app.effectiveCtx(ramGiB: 96), 32_768)
        app.selectedVariant = .flash
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
        app.selectedVariant = .flash  // the 393,216 floor is the 0731/Pro behavior
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
        app2.selectedVariant = .flash
        XCTAssertEqual(
            app2.requestThinkingMode(.max, currentCtx: 393_216, ramGiB: 128), .applied)
        XCTAssertEqual(app2.thinkingMode, .max)
    }

    /// Fresh installs select the expected model at each supported unified-memory tier.
    func testFreshInstallDefaultsFlash41From96GiB() {
        let a96 = AppState(
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!, ramGiB: 96)
        XCTAssertEqual(a96.selectedVariant, .flash41)
        let a128 = AppState(
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!, ramGiB: 128)
        XCTAssertEqual(a128.selectedVariant, .flash41)
        let a64 = AppState(
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!, ramGiB: 64)
        XCTAssertEqual(a64.selectedVariant, .flash)
        let a512 = AppState(
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!, ramGiB: 512)
        XCTAssertEqual(a512.selectedVariant, .pro)
    }

    func testStoredFlash0731IsNotSilentlyMigrated() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        defaults.set("flash", forKey: "selectedVariant")
        XCTAssertEqual(AppState(defaults: defaults, ramGiB: 128).selectedVariant, .flash)
    }

    func testFlash41QuantDefaultAndSelection() {
        let app = AppState(
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!, ramGiB: 128)
        XCTAssertEqual(app.selectedFlash41Quant, .q2)
        XCTAssertEqual(app.quantSelection, .flash41(.q2))
        app.selectedFlash41Quant = .q4
        XCTAssertEqual(app.quantSelection, .flash41(.q4))
        app.selectedVariant = .flash
        XCTAssertEqual(app.quantSelection, .flash(app.selectedFlashQuant))
        app.selectedVariant = .pro
        XCTAssertEqual(app.quantSelection, .pro)
    }

    func testFlash41QuantSelectionPersists() {
        let name = "test.\(UUID().uuidString)"
        let a1 = AppState(defaults: UserDefaults(suiteName: name)!, ramGiB: 128)
        a1.selectedFlash41Quant = .q4
        XCTAssertEqual(
            AppState(defaults: UserDefaults(suiteName: name)!, ramGiB: 128).selectedFlash41Quant,
            .q4)
    }

    func testFlash41MaxThinkNeedsNoCtxFloor() {
        let app = AppState(
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!, ramGiB: 128)
        XCTAssertEqual(app.selectedVariant, .flash41)
        XCTAssertEqual(
            app.requestThinkingMode(.max, currentCtx: 32_768, ramGiB: 128), .applied)
        XCTAssertEqual(app.thinkingMode, .max)
        XCTAssertTrue(app.applyMaxThinkCtxBump(ramGiB: 128))
        XCTAssertEqual(app.ctxOverride, 0)  // no floor to bump to
        XCTAssertEqual(app.effectiveCtx(ramGiB: 128), 32_768)
    }
}
