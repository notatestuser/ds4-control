import XCTest
@testable import DS4Control

final class VariantTests: XCTestCase {
    func testLayerCounts() {
        XCTAssertEqual(Variant.pro.layers, 61)
        XCTAssertEqual(Variant.flash.layers, 43)
    }
    func testCtxCeiling() {
        XCTAssertEqual(Variant.pro.ctxCeiling, 1_000_000)
        XCTAssertEqual(Variant.flash.ctxCeiling, 1_000_000)  // Flash also supports 1M
    }
    func testQuantSelection() {
        XCTAssertEqual(Quant.for(.pro, flashQuant: .q2q4).arg, "pro-q2-imatrix")  // Pro ignores flashQuant
        XCTAssertEqual(Quant.for(.flash, flashQuant: .q4).arg, "q4-imatrix")
        XCTAssertEqual(Quant.for(.flash, flashQuant: .q2).arg, "q2-imatrix")
        XCTAssertEqual(Quant.for(.flash, flashQuant: .q2q4).arg, "q2-q4-imatrix")
    }
    func testGgufFilenames() {
        XCTAssertEqual(
            Quant.for(.pro, flashQuant: .q2q4).ggufFilename,
            "DeepSeek-V4-Pro-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-Instruct-imatrix-0813.gguf")
        XCTAssertEqual(
            Quant.for(.flash, flashQuant: .q4).ggufFilename,
            "DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-imatrix-0731.gguf"
        )
        XCTAssertEqual(
            Quant.for(.flash, flashQuant: .q2).ggufFilename,
            "DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf")
        XCTAssertEqual(
            Quant.for(.flash, flashQuant: .q2q4).ggufFilename,
            "DeepSeek-V4-Flash-Layers37-42Q4KExperts-OtherExpertLayersIQ2XXSGateUp-Q2KDown-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-fixed-0731.gguf"
        )
    }
    func testLegacyPreviewFilenames() {
        XCTAssertEqual(Quant.legacyPreviewFilenames.count, 4)
        XCTAssertTrue(
            Quant.legacyPreviewFilenames.contains(
                "DeepSeek-V4-Pro-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-Instruct-imatrix.gguf"))
        for q in [Quant.proImatrix, .q2Imatrix, .q2q4Imatrix, .q4Imatrix] {
            XCTAssertFalse(Quant.legacyPreviewFilenames.contains(q.ggufFilename))
        }
    }
    func testKVCacheNamespacesAreGenerationSpecific() {
        XCTAssertEqual(Variant.pro.kvCacheDirectoryName, "kv-pro-0813")
        XCTAssertEqual(Variant.flash.kvCacheDirectoryName, "kv-flash-0731")
        XCTAssertNotEqual(Variant.pro.kvCacheDirectoryName, Variant.flash.kvCacheDirectoryName)
    }
    func testWeights() {
        XCTAssertEqual(Quant.for(.pro, flashQuant: .q2q4).weightsGiB, 432, accuracy: 1)
        XCTAssertEqual(Quant.for(.flash, flashQuant: .q4).weightsGiB, 153, accuracy: 1)
        XCTAssertEqual(Quant.for(.flash, flashQuant: .q2).weightsGiB, 81, accuracy: 1)
        XCTAssertEqual(Quant.for(.flash, flashQuant: .q2q4).weightsGiB, 91, accuracy: 1)

        XCTAssertEqual(Quant.proImatrix.ggufBytes, 464_627_334_560)
        XCTAssertEqual(Quant.q4Imatrix.ggufBytes, 164_633_502_592)
        XCTAssertEqual(Quant.q2Imatrix.ggufBytes, 86_720_111_488)
        XCTAssertEqual(Quant.q2q4Imatrix.ggufBytes, 97_591_747_456)
    }
    func testFlashQuant() {
        XCTAssertEqual(FlashQuant.allCases, [.q2, .q2q4, .q4])  // smallest → largest (picker order)
        XCTAssertEqual(FlashQuant.q2q4.rawValue, "q2-q4-imatrix")
        XCTAssertEqual(FlashQuant.q2.quant, .q2Imatrix)
        XCTAssertEqual(FlashQuant.q2q4.quant, .q2q4Imatrix)
        XCTAssertEqual(FlashQuant.q4.quant, .q4Imatrix)
        XCTAssertEqual(FlashQuant.q2q4.label, "0731-q2-q4-imatrix · ~91 GiB")  // 0731 generation + resident size
    }
    func testFlashQuantFitAndDefault() {
        XCTAssertEqual(defaultFlashQuant(ramGiB: 512), .q2q4)  // requested default fits
        XCTAssertEqual(defaultFlashQuant(ramGiB: 96), .q2)  // 96 GiB tier deliberately defaults to q2
        XCTAssertTrue(flashQuantFits(.q2, ramGiB: 96))
        XCTAssertFalse(flashQuantFits(.q2q4, ramGiB: 96))
        XCTAssertTrue(flashQuantFits(.q2q4, ramGiB: 128))
        XCTAssertTrue(flashQuantFits(.q4, ramGiB: 512))
        XCTAssertFalse(flashQuantFits(.q4, ramGiB: 128))
        XCTAssertFalse(flashQuantFits(.q4, ramGiB: 184))
        XCTAssertTrue(flashQuantFits(.q4, ramGiB: 185))
    }
    func testFlash41VariantIdentity() {
        XCTAssertEqual(Variant.flash41.displayName, "V4.1 Flash")
        XCTAssertEqual(Variant.flash41.modelId, "deepseek-v4.1-flash")
        XCTAssertEqual(Variant.flash41.kvCacheDirectoryName, "kv-flash-41")
        XCTAssertEqual(Variant.flash41.layers, 40)
        XCTAssertEqual(Variant.flash41.ctxCeiling, 1_048_576)
        XCTAssertEqual(Variant(rawValue: "flash41"), .flash41)
        XCTAssertEqual(Variant(rawValue: "flash"), .flash)  // 0731 raw value unchanged
        XCTAssertEqual(Variant.flash.kvCacheDirectoryName, "kv-flash-0731")
    }
    func testQuantSelectionMapping() {
        XCTAssertEqual(Quant.for(.pro), .proImatrix)
        XCTAssertEqual(Quant.for(.flash(.q4)), .q4Imatrix)
        XCTAssertEqual(Quant.for(.flash41(.q2)), .q41Q2)
        XCTAssertEqual(Quant.for(.flash41(.q4)), .q41Q4)
        XCTAssertEqual(QuantSelection.pro.variant, .pro)
        XCTAssertEqual(QuantSelection.flash(.q2q4).variant, .flash)
        XCTAssertEqual(QuantSelection.flash41(.q2).variant, .flash41)
        XCTAssertEqual(QuantSelection.flash41(.q2).quant, .q41Q2)
    }
    func testFlash41QuantConstants() {
        XCTAssertEqual(Quant.q41Q2.ggufFilename, "DeepSeek-V4.1-Flash-Q2.gguf")
        XCTAssertEqual(Quant.q41Q4.ggufFilename, "DeepSeek-V4.1-Flash-Q4.gguf")
        XCTAssertEqual(Quant.q41Q2.repo, "antirez/deepseek-v4.1-flash-gguf")
        XCTAssertEqual(Quant.proImatrix.repo, "antirez/deepseek-v4-gguf")
        XCTAssertEqual(Quant.q41Q2.ggufBytes, 365_713_686_528)
        XCTAssertEqual(Quant.q41Q4.ggufBytes, 518_596_067_328)
        // Whole file minus the 202,778,032,400 B of disk-only Engram rows (ds4 munmaps them).
        XCTAssertEqual(Quant.q41Q2.residentMainBytes, 162_935_654_128)
        XCTAssertEqual(Quant.q41Q4.residentMainBytes, 315_818_034_928)
        XCTAssertNil(Quant.q2Imatrix.residentMainBytes)
        XCTAssertEqual(
            Quant.q41Q2.sha256,
            "1ce6a8f8806205c13330d7ca287bd198331dc5ca35ccc5d8a9a92a188a6f6f42")
        XCTAssertEqual(
            Quant.q41Q4.sha256,
            "a5e2e2c3ada4b2e98d9f9e4b50f6d9c2a12c2c96f5da165c07e13aff9264984e")
        XCTAssertNil(Quant.proImatrix.sha256)
    }
    func testFlash41Q4Parts() {
        let parts = Quant.q41Q4.downloadParts
        XCTAssertEqual(
            parts.map(\.filename),
            ["DeepSeek-V4.1-Flash-Q4.gguf.part1", "DeepSeek-V4.1-Flash-Q4.gguf.part2"])
        XCTAssertEqual(parts.map(\.bytes), [480_000_000_000, 38_596_067_328])
        XCTAssertEqual(parts.reduce(0) { $0 + $1.bytes }, Int64(Quant.q41Q4.ggufBytes))
        XCTAssertEqual(
            parts[0].sha256,
            "6442b1f9224079662c02003c0ef9ef6be6e2aff509510f681dab9e6cc41df246")
        XCTAssertEqual(
            parts[1].sha256,
            "7c3e10646c918eeaffbc39305a75ec96117450262c61454ff194cef00d7617f0")
        XCTAssertEqual(Quant.q41Q2.downloadParts.count, 1)  // single file
        XCTAssertEqual(Quant.q41Q2.downloadParts[0].filename, Quant.q41Q2.ggufFilename)
        XCTAssertEqual(Quant.q41Q2.downloadParts[0].bytes, Int64(Quant.q41Q2.ggufBytes))
    }
    func testFlash41QuantLabels() {
        XCTAssertEqual(Flash41Quant.allCases, [.q2, .q4])  // smallest → largest (picker order)
        XCTAssertEqual(Flash41Quant.q2.quant, .q41Q2)
        XCTAssertEqual(Flash41Quant.q4.quant, .q41Q4)
        XCTAssertTrue(Flash41Quant.q2.label.contains("41-q2"))
        XCTAssertTrue(Flash41Quant.q4.label.contains("41-q4"))
    }
}
