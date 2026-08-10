import XCTest

@testable import DS4Control

/// The DSpark support model's identity plus the "will ds4 actually speculate?" gate. Both encode
/// facts about the engine, so they're pinned here rather than left to the call sites.
final class DSparkSupportTests: XCTestCase {
    /// The exact Hub filename and size. A wrong name is a 404 mid-download; a wrong size makes the
    /// Settings progress bar lie, since it's used as the total before the downloader reports one.
    func testSupportFileIdentity() {
        XCTAssertEqual(DSparkSupport.ggufFilename, "DeepSeek-V4-Flash-DSpark-support-0731.gguf")
        XCTAssertEqual(DSparkSupport.bytes, 5_989_114_272)
        XCTAssertEqual(DSparkSupport.giB, 5.578, accuracy: 0.001)
    }

    func testAppliesOnlyForSingleSessionFlash() {
        XCTAssertTrue(dsparkApplies(enabled: true, variant: .flash, sessions: 1))
    }

    /// Off is off, whatever else is configured.
    func testDoesNotApplyWhenDisabled() {
        XCTAssertFalse(dsparkApplies(enabled: false, variant: .flash, sessions: 1))
    }

    /// The support model is Flash-shaped; ds4 doesn't support V4 PRO, and a mismatched `--mtp`
    /// file fails engine open — so the flags must never be passed for Pro.
    func testDoesNotApplyToPro() {
        XCTAssertFalse(dsparkApplies(enabled: true, variant: .pro, sessions: 1))
    }

    /// `--batched-session N` puts ds4-server in batched mode, whose decode loop gates speculation
    /// on `!s->batched_mode` — DSpark would silently do nothing, so we don't claim it.
    func testDoesNotApplyWithBatchedSessions() {
        XCTAssertFalse(dsparkApplies(enabled: true, variant: .flash, sessions: 2))
        XCTAssertFalse(dsparkApplies(enabled: true, variant: .flash, sessions: 16))
    }
}
