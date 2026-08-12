import XCTest
@testable import DS4Control

final class FeasibilityTests: XCTestCase {
    func testDefaultCtxTieredByRAM() {
        // Pro & ≥128 GiB Flash → full 1M; 96–127 GiB Flash → 393K. Grounded in
        // scripts/flash-mem-harness.sh (q2 @1M ≈ 96 GiB resident → too tight below 128).
        XCTAssertEqual(defaultCtx(ramGiB: 600, variant: .pro, flashQuant: .q2q4), 1_000_000)
        XCTAssertEqual(defaultCtx(ramGiB: 512, variant: .pro, flashQuant: .q2q4), 1_000_000)
        XCTAssertEqual(defaultCtx(ramGiB: 256, variant: .flash, flashQuant: .q4), 1_000_000)
        XCTAssertEqual(defaultCtx(ramGiB: 128, variant: .flash, flashQuant: .q2q4), 1_000_000)
        XCTAssertEqual(defaultCtx(ramGiB: 127, variant: .flash, flashQuant: .q2), 393_216)
        XCTAssertEqual(defaultCtx(ramGiB: 96, variant: .flash, flashQuant: .q2), 393_216)
    }

    func testRAMBlocks() {
        if case .blocked = feasibility(
            ramGiB: 400, variant: .pro, flashQuant: .q2q4, ctx: 1_000_000, wiredLimitMB: Int.max)
        {
        } else {
            XCTFail("pro<512 must block")
        }
        if case .blocked = feasibility(
            ramGiB: 80, variant: .flash, flashQuant: .q2, ctx: 393_216, wiredLimitMB: Int.max)
        {
        } else {
            XCTFail("<96 blocked")
        }
    }

    func testRequiredWiredMB() {
        // q2 weights (81 GiB) + KV at 393K ctx (43 layers × 391 B/tok). KV always counts:
        // the disk KV cache is only a prompt cache — the active session's KV stays resident
        // (the harness measures the context buffers with --kv-disk-dir enabled).
        let kvMB = (43 * 391 * 393_216) / (1024 * 1024)
        XCTAssertEqual(
            requiredWiredMB(variant: .flash, flashQuant: .q2, ctx: 393_216),
            Int(Quant.q2Imatrix.weightsGiB * 1024) + kvMB)
        // Pro ignores the Flash quant choice; ctx 0 → weights only.
        XCTAssertEqual(
            requiredWiredMB(variant: .pro, flashQuant: .q2, ctx: 0),
            Int(Quant.proImatrix.weightsGiB * 1024))
    }

    func testWiredLimitGateFlash96() {
        // 96 GiB Flash q2 @393K: a default-ish cap (~75% ≈ 73,728 MB) gates; the advisory passes.
        // The advisory value leaves an 8 GiB OS buffer below total RAM.
        let advisory = Int((96.0 - 8.0) * 1024)
        guard
            case let .wiredLimitTooLow(required, adv) = feasibility(
                ramGiB: 96, variant: .flash, flashQuant: .q2, ctx: 393_216, wiredLimitMB: 73_728)
        else { return XCTFail("default-equivalent cap must gate") }
        XCTAssertEqual(required, requiredWiredMB(variant: .flash, flashQuant: .q2, ctx: 393_216))
        XCTAssertEqual(adv, advisory)
        XCTAssertEqual(
            feasibility(
                ramGiB: 96, variant: .flash, flashQuant: .q2, ctx: 393_216, wiredLimitMB: advisory),
            .standard)
    }

    func testWiredLimitGatePro512() {
        // Pro @1M needs ~455 GiB wired — a default 75% cap on 512 GiB (393,216 MB) gates;
        // the advisory (516,096 MB) passes.
        if case .wiredLimitTooLow = feasibility(
            ramGiB: 512, variant: .pro, flashQuant: .q2q4, ctx: 1_000_000, wiredLimitMB: 393_216)
        {
        } else {
            XCTFail("default 75% cap must gate Pro even on 512 GiB")
        }
        guard
            case let .wiredLimitTooLow(_, advisory) = feasibility(
                ramGiB: 512, variant: .pro, flashQuant: .q2q4, ctx: 1_000_000, wiredLimitMB: 393_216)
        else { return XCTFail() }
        XCTAssertEqual(advisory, Int((512.0 - 8.0) * 1024))  // 516096 MB
        XCTAssertEqual(
            feasibility(
                ramGiB: 512, variant: .pro, flashQuant: .q2q4, ctx: 1_000_000,
                wiredLimitMB: Int((512.0 - 8.0) * 1024)), .standard)
    }

    func testWiredLimitGateFlash128Q2Q4() {
        // q2-q4 @1M ≈ 107 GiB: a 75%-default 128 GiB machine (98,304 MB) gates — this tier
        // is NOT automatically standard — while a raised cap passes.
        if case .wiredLimitTooLow = feasibility(
            ramGiB: 128, variant: .flash, flashQuant: .q2q4, ctx: 1_000_000, wiredLimitMB: 98_304)
        {
        } else {
            XCTFail("98,304 MB cap must gate q2-q4 @1M")
        }
        XCTAssertEqual(
            feasibility(
                ramGiB: 128, variant: .flash, flashQuant: .q2q4, ctx: 1_000_000,
                wiredLimitMB: 110_000), .standard)
    }

    func testEffectiveWiredLimitLive() {
        let ram = systemRamGiB()
        XCTAssertGreaterThan(defaultWiredLimitMB(ramGiB: ram), 0)
        XCTAssertLessThanOrEqual(defaultWiredLimitMB(ramGiB: ram), Int(ram * 1024))
        let effective = effectiveWiredLimitMB(ramGiB: ram)
        XCTAssertGreaterThan(effective, 0)
        // When the user has raised the sysctl, the live read wins.
        if currentWiredLimitMB() > 0 { XCTAssertEqual(effective, currentWiredLimitMB()) }
    }

    func testEmulatedWiredLimitOverride() {
        // DS4_EMULATE_WIRED_LIMIT_MB wins over the live sysctl — preview the gated
        // notice without sudo.
        setenv("DS4_EMULATE_WIRED_LIMIT_MB", "20000", 1)
        defer { unsetenv("DS4_EMULATE_WIRED_LIMIT_MB") }
        XCTAssertEqual(emulatedWiredLimitMB(), 20_000)
        XCTAssertEqual(effectiveWiredLimitMB(ramGiB: 512), 20_000)
    }

    func testThinkMax() {
        XCTAssertTrue(thinkMax(ctx: 393_216))
        XCTAssertFalse(thinkMax(ctx: 392_000))
    }
    func testSystemRam() { XCTAssertGreaterThan(systemRamGiB(), 0) }
    func testWiredLimitReadable() { XCTAssertGreaterThanOrEqual(currentWiredLimitMB(), 0) }
}
