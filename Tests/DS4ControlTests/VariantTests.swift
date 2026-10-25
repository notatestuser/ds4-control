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
        XCTAssertEqual(Variant.flash41.displayName, "V4.1 1017")
        XCTAssertEqual(Variant.flash41.modelId, "deepseek-v4.1-flash")
        XCTAssertEqual(Variant.flash41.kvCacheDirectoryName, "kv-flash-41-1017")
        XCTAssertEqual(Variant.flash41.layers, 40)
        XCTAssertEqual(Variant.flash41.ctxCeiling, 1_048_576)
        XCTAssertEqual(Variant(rawValue: "flash41"), .flash41)
        XCTAssertEqual(Variant(rawValue: "flash"), .flash)
        XCTAssertEqual(Variant.flash.kvCacheDirectoryName, "kv-flash-0731")
    }
    func testQuantSelectionMapping() {
        XCTAssertEqual(Quant.for(.pro), .proImatrix)
        XCTAssertEqual(Quant.for(.flash(.q4)), .q4Imatrix)
        XCTAssertEqual(Quant.for(.flash41(.q2)), .q41Q2)
        XCTAssertEqual(Quant.for(.flash41(.mxfp4)), .q41MXFP4)
        XCTAssertEqual(QuantSelection.pro.variant, .pro)
        XCTAssertEqual(QuantSelection.flash(.q2q4).variant, .flash)
        XCTAssertEqual(QuantSelection.flash41(.q2).variant, .flash41)
        XCTAssertEqual(QuantSelection.flash41(.q2).quant, .q41Q2)
    }
    func testFlash41QuantConstants() {
        XCTAssertEqual(
            Quant.q41Q2.ggufFilename, "DeepSeek-V4.1-Flash-1017-IQ2_XXS-Q2_K-imatrix.gguf")
        XCTAssertEqual(
            Quant.q41MXFP4.ggufFilename, "DeepSeek-V4.1-Flash-1017-MXFP4-experts.gguf")
        XCTAssertEqual(Quant.q41Q2.arg, "ds41f-q2")
        XCTAssertEqual(Quant.q41MXFP4.arg, "ds41f-mxfp4")
        XCTAssertEqual(Quant.q41Q2.repo, "antirez/deepseek-v4.1-flash-gguf")
        XCTAssertEqual(Quant.proImatrix.repo, "antirez/deepseek-v4-gguf")
        XCTAssertEqual(Quant.q41Q2.ggufBytes, 365_713_686_528)
        XCTAssertEqual(Quant.q41MXFP4.ggufBytes, 501_609_136_128)
        // Real 1017 GGUF headers: the two disk-only tables contain these row counts,
        // at 264 bytes per row. Main-weight estimates retain the final file's padding.
        let engramBytes = (384_006_168 + 384_016_682) * 264
        XCTAssertEqual(engramBytes, 202_758_032_400)
        XCTAssertEqual(Quant.q41Q2.residentMainBytes, 162_955_654_128)
        XCTAssertEqual(Quant.q41MXFP4.residentMainBytes, 298_851_103_728)
        XCTAssertEqual(Quant.q41Q2.ggufBytes - engramBytes, Quant.q41Q2.residentMainBytes)
        XCTAssertEqual(Quant.q41MXFP4.ggufBytes - engramBytes, Quant.q41MXFP4.residentMainBytes)
        XCTAssertNil(Quant.q2Imatrix.residentMainBytes)
        XCTAssertEqual(
            Quant.q41Q2.sha256,
            "5296e85ff64b42ecb62c8d0c0c54e1caa07e3df8e93112f2365ebbaed62ce93a")
        XCTAssertEqual(
            Quant.q41MXFP4.sha256,
            "79608a69cd5bb919d8140c37105edc3a33419692d4e6caf4e68c901e4b359141")
        XCTAssertNil(Quant.proImatrix.sha256)
    }
    func testFlash41MXFP4ShardManifest() {
        // Published LFS manifest at the immutable Hub revision below, cross-checked
        // against ds4@a101246 download_model.sh. These are standard GGUF shards.
        let parts = Quant.q41MXFP4.downloadParts
        XCTAssertEqual(parts.count, 9)
        XCTAssertEqual(
            parts.map(\.filename),
            (1...9).map {
                "DeepSeek-V4.1-Flash-1017-MXFP4-experts-0000\($0)-of-00009.gguf"
            })
        XCTAssertEqual(
            parts.map(\.bytes),
            [
                49_353_784_544, 49_412_635_712, 49_582_960_352, 49_418_206_432,
                49_412_829_632, 49_257_603_776, 2_406_482_112, 101_377_628_544,
                101_380_404_256,
            ])
        XCTAssertEqual(
            parts.map(\.sha256),
            [
                "636918b09de6253bf41af29f06aac3ceeda220e46379d8a2058ef92c4e433ed8",
                "b26d3fc1e6ae1be6c52665542f3c1fee6a33791478f26e6cd90b5a75940a9f96",
                "20c7fe7adb0578336d8a5e5f9eed521aeb88e8c119ba46e0916cdaab28931c80",
                "67592ba15870c4292a615666adcc2736b53cc345b2cccb1c36710a0a6caf15b4",
                "ecd04e0aa71bfab8cfe79ea7fef7f35b6be0b6772455139e2081d6ce1dcc18ed",
                "88214e0cc80fbae578b80c114527e6ce725199684e0b6849475c7d00b3d0f54c",
                "38939faf3e4258f3ae333f0fa1954ce89515b75ceee90d37bf4ebe5fafe285e6",
                "a9d1634da2ac57459a64b10b69ddedfadda7dcde0e71ca6e55bea7c293c4a9f0",
                "b9832b355288c005da6ef444d02424464dd27f6ebdefeadbec2244264eb65285",
            ])
        XCTAssertEqual(Quant.q41MXFP4.assemblyFormat, .ggufShards)
        XCTAssertEqual(Quant.q41MXFP4.downloadBytes, 501_602_535_360)
        XCTAssertNotEqual(Quant.q41MXFP4.downloadBytes, Int64(Quant.q41MXFP4.ggufBytes))
        XCTAssertEqual(
            Quant.q41MXFP4.downloadRevision, "9dcee51692e6540f697141fc98b097e3c96492a3")
    }
    func testSingleFileManifestsRetainTransportSize() {
        for quant in [Quant.proImatrix, .q2Imatrix, .q2q4Imatrix, .q4Imatrix, .q41Q2] {
            XCTAssertEqual(quant.assemblyFormat, .singleFile)
            XCTAssertEqual(
                quant.downloadParts,
                [
                    QuantPart(filename: quant.ggufFilename, bytes: Int64(quant.ggufBytes), sha256: quant.sha256)
                ])
            XCTAssertEqual(quant.downloadBytes, Int64(quant.ggufBytes))
        }
        XCTAssertEqual(Quant.proImatrix.downloadRevision, "main")
        XCTAssertEqual(Quant.q2Imatrix.downloadRevision, "main")
        XCTAssertEqual(Quant.q41Q2.downloadRevision, Quant.q41MXFP4.downloadRevision)
    }
    func testFlash41QuantLabelsAndPersistedValues() {
        XCTAssertEqual(Flash41Quant.allCases, [.q2, .mxfp4])
        XCTAssertEqual(Flash41Quant.q2.quant, .q41Q2)
        XCTAssertEqual(Flash41Quant.mxfp4.quant, .q41MXFP4)
        XCTAssertEqual(Flash41Quant.q2.label, "1017-q2 · ~152 GiB (341 GiB on disk)")
        XCTAssertEqual(Flash41Quant.mxfp4.label, "1017-mxfp4 · ~278 GiB (467 GiB on disk)")
        XCTAssertEqual(Flash41Quant(rawValue: "q2"), .q2)
        XCTAssertEqual(Flash41Quant(rawValue: "mxfp4"), .mxfp4)
        XCTAssertNil(Flash41Quant(rawValue: "q4"))
    }
    func testFlash41CachesAreGenerationAndQuantSpecific() {
        XCTAssertEqual(QuantSelection.flash41(.q2).kvCacheDirectoryName, "kv-flash-41-1017-q2")
        XCTAssertEqual(QuantSelection.flash41(.mxfp4).kvCacheDirectoryName, "kv-flash-41-1017-mxfp4")
        XCTAssertEqual(QuantSelection.pro.kvCacheDirectoryName, "kv-pro-0813")
        for q in FlashQuant.allCases {
            XCTAssertEqual(QuantSelection.flash(q).kvCacheDirectoryName, "kv-flash-0731")
        }
    }
    func testLegacyFlash41FilenamesAreLimitedToPreviousGeneration() {
        XCTAssertEqual(
            Quant.legacyFlash41Filenames,
            [
                "DeepSeek-V4.1-Flash-Q2.gguf", "DeepSeek-V4.1-Flash-Q4.gguf",
                "DeepSeek-V4.1-Flash-Q4.gguf.part1", "DeepSeek-V4.1-Flash-Q4.gguf.part2",
            ])
        for quant in [Quant.q41Q2, .q41MXFP4] {
            XCTAssertFalse(Quant.legacyFlash41Filenames.contains(quant.ggufFilename))
            for part in quant.downloadParts {
                XCTAssertFalse(Quant.legacyFlash41Filenames.contains(part.filename))
            }
        }
    }
}
