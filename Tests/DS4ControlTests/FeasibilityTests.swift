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

    /// The sessions stepper's ceiling: the largest slot count that passes the wired-limit
    /// gate without the "Start anyway" override, capped at the 16-session app limit.
    func testMaxFittingSessionsStopsAtTheWiredLimit() {
        // 96 GiB Flash q2 @256K: one session needs 93,390 MB, two 97,787 MB; the advisory
        // limit (94,208 MB) fits exactly one.
        XCTAssertEqual(
            maxFittingSessions(
                ramGiB: 96, selection: .flash(.q2), ctx: 256_000, wiredLimitMB: 94_208), 1)
        // A limit between the two- and three-session working sets (97,787 / 102,184 MB)
        // fits exactly two.
        XCTAssertEqual(
            maxFittingSessions(
                ramGiB: 512, selection: .flash(.q2), ctx: 256_000, wiredLimitMB: 100_000), 2)
        // Raised above any need, the count maxes out at the app ceiling.
        XCTAssertEqual(
            maxFittingSessions(
                ramGiB: 512, selection: .flash(.q2), ctx: 256_000, wiredLimitMB: Int.max),
            maxConcurrentSessions)
        // Pro @1M needs 501,637 MB for one session and 529,517 MB for two: even the
        // advisory limit on 512 GiB (520,192 MB) fits one.
        XCTAssertEqual(
            maxFittingSessions(
                ramGiB: 512, selection: .pro, ctx: 1_000_000, wiredLimitMB: 520_192), 1)
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

    // MARK: - DeepSeek V4.1 Flash

    func testDS41GraphBytesMatchPinnedDS4Estimator() {
        // Fixed values from a transcription of ds4@bd66c40 `ds41_graph_bytes`
        // (external/ds4/ds4.c:39227) verified with an independent dev-time calculation.
        // Keep them independent of the Swift formula so drift fails loudly.
        XCTAssertEqual(ds41GraphBytes(ctx: 4_096), 1_921_216_616)
        XCTAssertEqual(ds41GraphBytes(ctx: 32_768), 8_465_702_760)
        XCTAssertEqual(ds41GraphBytes(ctx: 131_072), 9_610_852_200)
        XCTAssertEqual(ds41GraphBytes(ctx: 393_216), 12_664_584_040)
        XCTAssertEqual(ds41GraphBytes(ctx: 1_048_576), 20_298_913_640)
        XCTAssertNil(ds41GraphBytes(ctx: 0))
        XCTAssertNil(ds41GraphBytes(ctx: 1_048_577))  // above max_position_embeddings
    }

    func testV41FixedWiredMatchesPinnedValues() {
        // fixed = resident (or streamed) weights + graph × sessions + 2 GiB
        // (+ the 2-layer streaming prefill headroom), rounded up to MiB. Values mirror
        // ds41_memory_admit_for_host and the GGUF byte constants.
        XCTAssertEqual(
            v41FixedWiredMB(quant: .q41Q2, ctx: 32_768, sessions: 1, streaming: true), 27_007)
        XCTAssertEqual(
            v41FixedWiredMB(quant: .q41Q2, ctx: 32_768, sessions: 1, streaming: false), 165_510)
        XCTAssertEqual(
            v41FixedWiredMB(quant: .q41Q4, ctx: 32_768, sessions: 1, streaming: true), 34_297)
        XCTAssertEqual(
            v41FixedWiredMB(quant: .q41Q4, ctx: 32_768, sessions: 1, streaming: false), 311_310)
        XCTAssertEqual(
            v41FixedWiredMB(quant: .q41Q2, ctx: 1_048_576, sessions: 1, streaming: true), 38_292)
    }

    func testFlash41StreamingDecisionMirrorsBudget() {
        // budget = min(ram × 7/8, recommended working set); recommended ≈ 75% of RAM here.
        XCTAssertTrue(
            flash41UsesSSDStreaming(
                ramGiB: 128, wiredLimitMB: 98_304, quant: .q41Q2, ctx: 32_768, sessions: 1))
        XCTAssertFalse(
            flash41UsesSSDStreaming(
                ramGiB: 512, wiredLimitMB: 393_216, quant: .q41Q2, ctx: 32_768, sessions: 1))
        XCTAssertFalse(
            flash41UsesSSDStreaming(
                ramGiB: 256, wiredLimitMB: 196_608, quant: .q41Q2, ctx: 32_768, sessions: 1))
        XCTAssertTrue(
            flash41UsesSSDStreaming(
                ramGiB: 256, wiredLimitMB: 196_608, quant: .q41Q4, ctx: 32_768, sessions: 1))
        XCTAssertFalse(
            flash41UsesSSDStreaming(
                ramGiB: 512, wiredLimitMB: 393_216, quant: .q41Q4, ctx: 32_768, sessions: 1))
    }

    func testFlash41FloorsAndGates() {
        if case let .blocked(reason) = feasibility(
            ramGiB: 96, selection: .flash41(.q2), ctx: 32_768, wiredLimitMB: 86_016)
        {
            XCTAssertTrue(reason.contains("128 GiB"))
        } else {
            XCTFail("V4.1 below 128 GiB must block")
        }
        if case .standard = feasibility(
            ramGiB: 128, selection: .flash41(.q2), ctx: 32_768, wiredLimitMB: 98_304)
        {
        } else {
            XCTFail("V4.1 q2 on 128 GiB with streaming must pass")
        }
        if case let .blocked(reason) = feasibility(
            ramGiB: 128, selection: .flash41(.q4), ctx: 32_768, wiredLimitMB: Int.max)
        {
            XCTAssertTrue(reason.contains("256 GiB"))
        } else {
            XCTFail("V4.1 41-q4 below 256 GiB must block (documented tier table)")
        }
        if case .standard = feasibility(
            ramGiB: 256, selection: .flash41(.q4), ctx: 32_768, wiredLimitMB: 196_608)
        {
        } else {
            XCTFail("V4.1 q4 on 256 GiB with streaming must pass")
        }
    }

    func testFlash41QuantFitFloors() {
        XCTAssertFalse(flash41QuantFits(.q2, ramGiB: 96, wiredLimitMB: Int.max))
        XCTAssertFalse(flash41QuantFits(.q4, ramGiB: 96, wiredLimitMB: Int.max))
        XCTAssertTrue(flash41QuantFits(.q2, ramGiB: 128, wiredLimitMB: 98_304))
        // 41-q4's documented floor is 256 GiB (README tier table): the 128 GiB class streams
        // essentially every routed expert, which the supported tiers do not offer.
        XCTAssertFalse(flash41QuantFits(.q4, ramGiB: 128, wiredLimitMB: Int.max))
        XCTAssertFalse(flash41QuantFits(.q4, ramGiB: 255, wiredLimitMB: Int.max))
        XCTAssertTrue(flash41QuantFits(.q4, ramGiB: 256, wiredLimitMB: 196_608))
    }

    func testFlash41DefaultCtxAndQuant() {
        // Streaming tiers keep upstream's documented 32,768 default: 41-q2 on 128 GiB, and
        // 41-q4 through its 256 GiB floor (the 1M window doesn't fit fully resident yet).
        XCTAssertEqual(defaultCtx(ramGiB: 128, selection: .flash41(.q2)), 32_768)
        XCTAssertEqual(defaultCtx(ramGiB: 256, selection: .flash41(.q4)), 32_768)
        // Tiers that hold the full 1M window resident default to the ceiling instead.
        XCTAssertEqual(defaultCtx(ramGiB: 256, selection: .flash41(.q2)), 1_048_576)
        XCTAssertEqual(defaultCtx(ramGiB: 384, selection: .flash41(.q4)), 1_048_576)
        XCTAssertEqual(defaultCtx(ramGiB: 512, selection: .flash41(.q4)), 1_048_576)
        XCTAssertEqual(defaultFlash41Quant(ramGiB: 128), .q2)
        XCTAssertEqual(defaultFlash41Quant(ramGiB: 512), .q4)
    }

    func testSystemRam() { XCTAssertGreaterThan(systemRamGiB(), 0) }
    func testWiredLimitReadable() { XCTAssertGreaterThanOrEqual(currentWiredLimitMB(), 0) }
}
