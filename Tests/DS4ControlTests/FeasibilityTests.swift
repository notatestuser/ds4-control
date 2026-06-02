import XCTest
@testable import DS4Control

final class FeasibilityTests: XCTestCase {
    func testDefaultCtxIsUniversal1M() {
        // 1M wherever the weights fit (live KV is small; mmap'd weights page lazily). Grounded
        // in scripts/flash-mem-harness.sh.
        XCTAssertEqual(defaultCtx(ramGiB: 600, variant: .pro, flashQuant: .q2q4), 1_000_000)
        XCTAssertEqual(defaultCtx(ramGiB: 512, variant: .pro, flashQuant: .q2q4), 1_000_000)
        XCTAssertEqual(defaultCtx(ramGiB: 128, variant: .flash, flashQuant: .q2q4), 1_000_000)
        XCTAssertEqual(defaultCtx(ramGiB: 96, variant: .flash, flashQuant: .q2), 1_000_000)
    }
    func testDefaultCtxFallsBackWhenWeightsDontFit() {
        // Degenerate: weights + OS reserve exceed RAM → floor to 32768.
        XCTAssertEqual(defaultCtx(ramGiB: 85, variant: .flash, flashQuant: .q2), 32_768)
        XCTAssertEqual(defaultCtx(ramGiB: 96, variant: .flash, flashQuant: .q4), 32_768)
    }
    func testFeasibilityGate() {
        if case .warnWiredLimit = feasibility(ramGiB: 520, variant: .pro) {
        } else {
            XCTFail("pro≥512 warns to raise the wired limit")
        }
        if case .blocked = feasibility(ramGiB: 400, variant: .pro) {} else { XCTFail("pro<512 must block") }
        XCTAssertEqual(feasibility(ramGiB: 130, variant: .flash), .standard)
        if case .warnWiredLimit = feasibility(ramGiB: 100, variant: .flash) {} else { XCTFail("96-127 warns") }
        if case .unsupported = feasibility(ramGiB: 80, variant: .flash) {} else { XCTFail("<96 unsupported") }
    }
    func testWiredLimitAdvisory() {
        // Advisory leaves an 8 GiB OS buffer below total RAM (so the GPU-wired set fits).
        if case let .warnWiredLimit(mb) = feasibility(ramGiB: 96, variant: .flash) {
            XCTAssertEqual(mb, Int((96.0 - 8.0) * 1024))
        } else {
            XCTFail("flash 96 warns")
        }
        if case let .warnWiredLimit(mb) = feasibility(ramGiB: 512, variant: .pro) {
            XCTAssertEqual(mb, Int((512.0 - 8.0) * 1024))  // 516096 MB
        } else {
            XCTFail("pro 512 warns")
        }
    }
    func testThinkMax() {
        XCTAssertTrue(thinkMax(ctx: 393_216))
        XCTAssertFalse(thinkMax(ctx: 392_000))
    }
    func testSystemRam() { XCTAssertGreaterThan(systemRamGiB(), 0) }
    func testWiredLimitReadable() { XCTAssertGreaterThanOrEqual(currentWiredLimitMB(), 0) }
}
