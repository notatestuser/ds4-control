import XCTest
@testable import DS4Control

final class FeasibilityTests: XCTestCase {
    func testDefaultCtxTieredByRAM() {
        // Pro & ≥128 GiB Flash → full 1M; 96–127 GiB Flash → 256K. Grounded in
        // the complete q2 working set fitting below the 96 GiB tier's 4 GiB reserve.
        XCTAssertEqual(defaultCtx(ramGiB: 600, variant: .pro, flashQuant: .q2q4), 1_000_000)
        XCTAssertEqual(defaultCtx(ramGiB: 512, variant: .pro, flashQuant: .q2q4), 1_000_000)
        XCTAssertEqual(defaultCtx(ramGiB: 256, variant: .flash, flashQuant: .q4), 1_000_000)
        XCTAssertEqual(defaultCtx(ramGiB: 128, variant: .flash, flashQuant: .q2q4), 1_000_000)
        XCTAssertEqual(defaultCtx(ramGiB: 127, variant: .flash, flashQuant: .q2), 256_000)
        XCTAssertEqual(defaultCtx(ramGiB: 96, variant: .flash, flashQuant: .q2), 256_000)
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
        // Fixed values from the pinned ds4 Metal context, graph, and persistent backend
        // allocators plus exact Hugging Face GGUF byte sizes. Keep these independent of
        // the Swift formula.
        XCTAssertEqual(requiredWiredMB(variant: .flash, flashQuant: .q2, ctx: 256_000), 93_390)
        XCTAssertEqual(requiredWiredMB(variant: .flash, flashQuant: .q2, ctx: 393_216), 96_626)
        XCTAssertEqual(requiredWiredMB(variant: .flash, flashQuant: .q4, ctx: 1_000_000), 185_166)
        XCTAssertEqual(requiredWiredMB(variant: .pro, flashQuant: .q2, ctx: 1_000_000), 501_637)
        // Pro ignores the Flash quant choice; ctx 0 → weights only.
        XCTAssertEqual(requiredWiredMB(variant: .pro, flashQuant: .q2, ctx: 0), 443_104)
    }

    func testProPrefillCapNeverExceedsShortLongPrompt() {
        // Pinned ds4 selects the 8,192-token Pro chunk above 4,096, then caps it
        // to the actual prompt length before estimating scratch allocation.
        XCTAssertEqual(requiredWiredMB(variant: .pro, flashQuant: .q2, ctx: 4_097), 451_243)
    }

    func testRequiredMemoryDisplayRoundsUpToGiB() {
        XCTAssertEqual(roundedUpGiB(fromMB: 90_899), 89)
        XCTAssertEqual(roundedUpGiB(fromMB: 90_112), 88)
        XCTAssertEqual(roundedUpGiB(fromMB: 0), 0)
    }

    func testRequiredWiredMBScalesResidentKVBySessions() {
        XCTAssertEqual(
            requiredWiredMB(variant: .flash, flashQuant: .q2, ctx: 256_000, sessions: 1),
            93_390)
        XCTAssertEqual(
            requiredWiredMB(variant: .flash, flashQuant: .q2, ctx: 256_000, sessions: 2),
            97_787)
    }

    func testWiredLimitRejectsFractionalKVOverage() {
        // Exact q2 weights round to 82,703 MiB. At 256K, pinned ds4's context,
        // graph, and conservative persistent-scratch allocations total
        // 11,205,727,248 bytes, whose fractional MiB must round upward.
        let truncatedRequiredMB = 82_703 + 11_205_727_248 / (1024 * 1024)
        guard
            case let .wiredLimitTooLow(requiredMB, _) = feasibility(
                ramGiB: 96, variant: .flash, flashQuant: .q2, ctx: 256_000,
                wiredLimitMB: truncatedRequiredMB)
        else { return XCTFail("a limit below the full fractional KV allocation must be rejected") }
        XCTAssertEqual(requiredMB, truncatedRequiredMB + 1)
    }

    func testWiredLimitRejectsLimitThatOmitsSharedAllocations() {
        let weightsAndContextOnlyMB = 87_079
        guard
            case let .wiredLimitTooLow(requiredMB, advisoryMB) = feasibility(
                ramGiB: 96, variant: .flash, flashQuant: .q2, ctx: 256_000,
                wiredLimitMB: weightsAndContextOnlyMB)
        else { return XCTFail("a limit that omits shared graph/backend allocations must be rejected") }
        XCTAssertEqual(requiredMB, 93_390)
        XCTAssertEqual(advisoryMB, 94_208)
    }

    func testPersistentIndexerScratchBuffersAreIncludedInWiredRequirement() {
        let requirementWithoutIndexerScratch = 91_398
        guard
            case let .wiredLimitTooLow(requiredMB, _) = feasibility(
                ramGiB: 96, variant: .flash, flashQuant: .q2, ctx: 256_000,
                wiredLimitMB: requirementWithoutIndexerScratch)
        else { return XCTFail("the persistent indexer scratch must be part of the wired gate") }
        XCTAssertEqual(requiredMB, requirementWithoutIndexerScratch + 1_992)
    }

    func testSortedIndexerBufferBlocksProAtReserveBoundary() {
        let usableMB = wiredLimitAdvisoryMB(ramGiB: 512)
        XCTAssertEqual(usableMB, 520_192)
        XCTAssertEqual(
            requiredWiredMB(
                variant: .pro, flashQuant: .q2, ctx: 867_452, sessions: 2),
            520_224)
        guard
            case .blocked = feasibility(
                ramGiB: 512, variant: .pro, flashQuant: .q2, ctx: 867_452,
                wiredLimitMB: usableMB, sessions: 2)
        else { return XCTFail("the separately retained sorted-index buffer must consume reserve") }
    }

    func testRequiredWiredMBSaturatesOnOverflow() {
        XCTAssertEqual(
            requiredWiredMB(variant: .flash, flashQuant: .q2, ctx: Int.max, sessions: Int.max),
            Int.max)
    }

    func testWorkingSetAbovePhysicalRAMBlocks() {
        guard
            case let .blocked(reason) = feasibility(
                ramGiB: 96, variant: .flash, flashQuant: .q2, ctx: 1_000_000,
                wiredLimitMB: Int.max)
        else { return XCTFail("Flash q2 at 1M context must not be offered a wired-limit workaround on 96 GiB") }
        XCTAssertTrue(reason.contains("Reduce context or concurrent sessions"))
    }

    func testWorkingSetThatConsumesOSReserveBlocks() {
        let required = requiredWiredMB(variant: .flash, flashQuant: .q2, ctx: 300_000)
        let usableMB = wiredLimitAdvisoryMB(ramGiB: 96)
        XCTAssertEqual(required, 94_431)
        XCTAssertGreaterThan(required, usableMB)
        XCTAssertLessThan(required, 96 * 1024)

        guard
            case let .blocked(reason) = feasibility(
                ramGiB: 96, variant: .flash, flashQuant: .q2, ctx: 300_000,
                wiredLimitMB: Int.max)
        else { return XCTFail("a setup that consumes the macOS reserve must be blocked") }
        XCTAssertTrue(reason.contains("needs ~93 GiB unified memory"))
        XCTAssertTrue(reason.contains("macOS needs ~4 GiB"))
    }

    func testProSessionsThatExceedPhysicalRAMBlockUsingDs4Allocation() {
        guard
            case let .blocked(reason) = feasibility(
                ramGiB: 512, variant: .pro, flashQuant: .q2, ctx: 1_000_000,
                wiredLimitMB: 516_096, sessions: 3)
        else { return XCTFail("three Pro sessions exceed 512 GiB with ds4's real context allocation") }
        XCTAssertEqual(requiredWiredMB(variant: .pro, flashQuant: .q2, ctx: 1_000_000, sessions: 3), 557_397)
        XCTAssertTrue(reason.contains("Reduce context or concurrent sessions"))
    }

    func testLaunchBoundsBlockBeforeSizing() {
        XCTAssertEqual(
            feasibility(
                ramGiB: 128, variant: .flash, flashQuant: .q2, ctx: Int.max,
                wiredLimitMB: Int.max, sessions: Int.max),
            .blocked(reason: "Context size must be between 1 and 1,000,000 tokens."))
    }

    func testWiredLimitGateFlash96() {
        // 96 GiB Flash q2 @256K: a default-ish cap (~75% ≈ 73,728 MB) gates; the advisory passes.
        // The advisory value leaves a 4 GiB OS buffer below total RAM.
        let advisory = Int((96.0 - 4.0) * 1024)
        guard
            case let .wiredLimitTooLow(required, adv) = feasibility(
                ramGiB: 96, variant: .flash, flashQuant: .q2, ctx: 256_000, wiredLimitMB: 73_728)
        else { return XCTFail("default-equivalent cap must gate") }
        XCTAssertEqual(required, requiredWiredMB(variant: .flash, flashQuant: .q2, ctx: 256_000))
        XCTAssertEqual(adv, advisory)
        XCTAssertEqual(
            feasibility(
                ramGiB: 96, variant: .flash, flashQuant: .q2, ctx: 256_000, wiredLimitMB: advisory),
            .standard)
    }

    func testMaxThinkContextDoesNotFit96GiBTierReserve() {
        guard
            case .blocked = feasibility(
                ramGiB: 96, variant: .flash, flashQuant: .q2, ctx: thinkMaxMinCtx,
                wiredLimitMB: Int.max)
        else { return XCTFail("Max Think context must not consume the low-memory tier's reserve") }
    }

    func testWiredLimitGatePro512() {
        // Pro @1M needs ~490 GiB wired — a default 75% cap on 512 GiB (393,216 MB) gates;
        // the advisory (520,192 MB) passes.
        if case .wiredLimitTooLow = feasibility(
            ramGiB: 512, variant: .pro, flashQuant: .q2q4, ctx: 1_000_000, wiredLimitMB: 393_216)
        {
        } else {
            XCTFail("default 75% cap must gate Pro even on 512 GiB")
        }
        guard
            case let .wiredLimitTooLow(_, advisory) = feasibility(
                ramGiB: 512, variant: .pro, flashQuant: .q2q4, ctx: 1_000_000, wiredLimitMB: 393_216)
        else { return XCTFail("expected feasibility to return wiredLimitTooLow for V4 Pro") }
        XCTAssertEqual(advisory, Int((512.0 - 4.0) * 1024))  // 520192 MB
        XCTAssertEqual(
            feasibility(
                ramGiB: 512, variant: .pro, flashQuant: .q2q4, ctx: 1_000_000,
                wiredLimitMB: Int((512.0 - 4.0) * 1024)), .standard)
    }

    func testWiredLimitGateFlash128Q2Q4() {
        // q2-q4 @1M ≈ 118 GiB: a 75%-default 128 GiB machine (98,304 MB) gates — this tier
        // is NOT automatically standard — while a raised cap passes.
        if case .wiredLimitTooLow = feasibility(
            ramGiB: 128, variant: .flash, flashQuant: .q2q4, ctx: 1_000_000, wiredLimitMB: 98_304)
        {
        } else {
            XCTFail("98,304 MB cap must gate q2-q4 @1M")
        }
        let required = requiredWiredMB(variant: .flash, flashQuant: .q2q4, ctx: 1_000_000)
        XCTAssertEqual(required, 121_230)
        if case .wiredLimitTooLow = feasibility(
            ramGiB: 128, variant: .flash, flashQuant: .q2q4, ctx: 1_000_000,
            wiredLimitMB: 110_000)
        {
        } else {
            XCTFail("a cap that omits the shared graph workspace must gate q2-q4 @1M")
        }
        XCTAssertEqual(
            feasibility(
                ramGiB: 128, variant: .flash, flashQuant: .q2q4, ctx: 1_000_000,
                wiredLimitMB: required), .standard)
    }

    func testWiredLimitAdvisoryFitsWorkingSetWithoutConsumingOSReserve() {
        let usableMB = wiredLimitAdvisoryMB(ramGiB: 128)
        guard
            case let .wiredLimitTooLow(required, advisory) = feasibility(
                ramGiB: 128, variant: .flash, flashQuant: .q2q4, ctx: 1_000_000,
                wiredLimitMB: 98_304)
        else { return XCTFail("expected the default wired limit to gate this setup") }
        XCTAssertGreaterThanOrEqual(advisory, required)
        XCTAssertEqual(advisory, usableMB)
        XCTAssertLessThan(advisory, 128 * 1024)
    }

    func testEffectiveWiredLimitLive() {
        let inheritedOverride = ProcessInfo.processInfo.environment["DS4_EMULATE_WIRED_LIMIT_MB"]
        unsetenv("DS4_EMULATE_WIRED_LIMIT_MB")
        defer {
            if let inheritedOverride {
                setenv("DS4_EMULATE_WIRED_LIMIT_MB", inheritedOverride, 1)
            } else {
                unsetenv("DS4_EMULATE_WIRED_LIMIT_MB")
            }
        }
        let ram = systemRamGiB()
        XCTAssertGreaterThan(defaultWiredLimitMB(ramGiB: ram), 0)
        XCTAssertLessThanOrEqual(defaultWiredLimitMB(ramGiB: ram), Int(ram * 1024))
        let effective = effectiveWiredLimitMB(ramGiB: ram)
        XCTAssertGreaterThan(effective, 0)
        // When the user has raised the sysctl, the live read wins.
        if currentWiredLimitMB() > 0 { XCTAssertEqual(effective, currentWiredLimitMB()) }
    }

    func testEmulatedWiredLimitOverride() {
        let inheritedOverride = ProcessInfo.processInfo.environment["DS4_EMULATE_WIRED_LIMIT_MB"]
        defer {
            if let inheritedOverride {
                setenv("DS4_EMULATE_WIRED_LIMIT_MB", inheritedOverride, 1)
            } else {
                unsetenv("DS4_EMULATE_WIRED_LIMIT_MB")
            }
        }
        #if DEBUG
            // DS4_EMULATE_WIRED_LIMIT_MB wins over the live sysctl — preview the gated
            // notice without sudo.
            setenv("DS4_EMULATE_WIRED_LIMIT_MB", "20000", 1)
            XCTAssertEqual(emulatedWiredLimitMB(), 20_000)
            XCTAssertEqual(effectiveWiredLimitMB(ramGiB: 512), 20_000)
        #else
            setenv("DS4_EMULATE_WIRED_LIMIT_MB", "20000", 1)
            XCTAssertNil(emulatedWiredLimitMB())
        #endif
    }

    func testThinkMax() {
        XCTAssertTrue(thinkMax(ctx: 393_216))
        XCTAssertFalse(thinkMax(ctx: 392_000))
    }
    func testSystemRam() { XCTAssertGreaterThan(systemRamGiB(), 0) }
    func testWiredLimitReadable() { XCTAssertGreaterThanOrEqual(currentWiredLimitMB(), 0) }
}
