import XCTest
@testable import DS4Control

final class FeasibilityTests: XCTestCase {
    func testDefaultCtxAnchors() {
        XCTAssertEqual(defaultCtx(ramGiB: 600, variant: .pro), 1_000_000)  // default at 1M ceiling
        XCTAssertEqual(defaultCtx(ramGiB: 128, variant: .flash), 393_216)
        XCTAssertEqual(defaultCtx(ramGiB: 96, variant: .flash), 250_000)
    }
    func testDefaultCtxProgressiveStepDown() {
        XCTAssertEqual(defaultCtx(ramGiB: 93, variant: .flash), 131_072)
        XCTAssertEqual(defaultCtx(ramGiB: 92, variant: .flash), 65_536)
        XCTAssertEqual(defaultCtx(ramGiB: 90, variant: .flash), 32_768)  // floor
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
}
