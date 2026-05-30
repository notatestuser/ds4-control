import XCTest
@testable import DS4Control

final class FeasibilityTests: XCTestCase {
    func testDefaultCtxAnchors() {
        XCTAssertEqual(defaultCtx(ramGiB: 600, variant: .pro), 786_432)  // default capped at 768K
        XCTAssertEqual(defaultCtx(ramGiB: 128, variant: .flash), 393_216)
        XCTAssertEqual(defaultCtx(ramGiB: 96, variant: .flash), 250_000)
    }
    func testDefaultCtxProgressiveStepDown() {
        XCTAssertEqual(defaultCtx(ramGiB: 93, variant: .flash), 131_072)
        XCTAssertEqual(defaultCtx(ramGiB: 92, variant: .flash), 65_536)
        XCTAssertEqual(defaultCtx(ramGiB: 90, variant: .flash), 32_768)  // floor
    }
    func testFeasibilityGate() {
        XCTAssertEqual(feasibility(ramGiB: 520, variant: .pro), .standard)
        if case .blocked = feasibility(ramGiB: 400, variant: .pro) {} else { XCTFail("pro<512 must block") }
        XCTAssertEqual(feasibility(ramGiB: 130, variant: .flash), .standard)
        if case .warnWiredLimit = feasibility(ramGiB: 100, variant: .flash) {} else { XCTFail("96-127 warns") }
        if case .unsupported = feasibility(ramGiB: 80, variant: .flash) {} else { XCTFail("<96 unsupported") }
    }
    func testWiredLimitAdvisory() {
        if case let .warnWiredLimit(mb) = feasibility(ramGiB: 96, variant: .flash) {
            XCTAssertEqual(mb, Int(96.0 * 1024 * 0.9))
        } else {
            XCTFail()
        }
    }
    func testThinkMax() {
        XCTAssertTrue(thinkMax(ctx: 393_216))
        XCTAssertFalse(thinkMax(ctx: 392_000))
    }
    func testSystemRam() { XCTAssertGreaterThan(systemRamGiB(), 0) }
}
