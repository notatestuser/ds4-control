import XCTest
@testable import DS4Control

final class VariantTests: XCTestCase {
    func testKVBytesPerToken() {
        XCTAssertEqual(Variant.pro.kvBytesPerToken, 23_851)  // 61 layers × 391
        XCTAssertEqual(Variant.flash.kvBytesPerToken, 16_813)  // 43 layers × 391 (measured)
    }
    func testCtxCeiling() {
        XCTAssertEqual(Variant.pro.ctxCeiling, 1_000_000)
        XCTAssertEqual(Variant.flash.ctxCeiling, 1_000_000)  // Flash also supports 1M
    }
    func testQuantSelection() {
        XCTAssertEqual(Quant.for(.pro, flashQuant: .q2q4).arg, "pro-imatrix")  // Pro ignores flashQuant
        XCTAssertEqual(Quant.for(.flash, flashQuant: .q4).arg, "q4-imatrix")
        XCTAssertEqual(Quant.for(.flash, flashQuant: .q2).arg, "q2-imatrix")
        XCTAssertEqual(Quant.for(.flash, flashQuant: .q2q4).arg, "q2-q4-imatrix")
    }
    func testGgufFilenames() {
        XCTAssertEqual(
            Quant.for(.pro, flashQuant: .q2q4).ggufFilename,
            "DeepSeek-V4-Pro-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-Instruct-imatrix.gguf")
        XCTAssertEqual(
            Quant.for(.flash, flashQuant: .q4).ggufFilename,
            "DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-imatrix.gguf")
        XCTAssertEqual(
            Quant.for(.flash, flashQuant: .q2).ggufFilename,
            "DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix.gguf")
        XCTAssertEqual(
            Quant.for(.flash, flashQuant: .q2q4).ggufFilename,
            "DeepSeek-V4-Flash-Layers37-42Q4KExperts-OtherExpertLayersIQ2XXSGateUp-Q2KDown-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-fixed.gguf"
        )
    }
    func testWeights() {
        XCTAssertEqual(Quant.for(.pro, flashQuant: .q2q4).weightsGiB, 432, accuracy: 1)
        XCTAssertEqual(Quant.for(.flash, flashQuant: .q4).weightsGiB, 153, accuracy: 1)
        XCTAssertEqual(Quant.for(.flash, flashQuant: .q2).weightsGiB, 81, accuracy: 1)
        XCTAssertEqual(Quant.for(.flash, flashQuant: .q2q4).weightsGiB, 91, accuracy: 1)
    }
    func testFlashQuant() {
        XCTAssertEqual(FlashQuant.allCases, [.q2, .q2q4, .q4])  // smallest → largest (picker order)
        XCTAssertEqual(FlashQuant.q2q4.rawValue, "q2-q4-imatrix")
        XCTAssertEqual(FlashQuant.q2.quant, .q2Imatrix)
        XCTAssertEqual(FlashQuant.q2q4.quant, .q2q4Imatrix)
        XCTAssertEqual(FlashQuant.q4.quant, .q4Imatrix)
        XCTAssertEqual(FlashQuant.q2q4.label, "q2-q4-imatrix · ~91 GiB")  // resident size
    }
    func testFlashQuantFitAndDefault() {
        XCTAssertEqual(defaultFlashQuant(ramGiB: 512), .q2q4)  // requested default fits
        XCTAssertEqual(defaultFlashQuant(ramGiB: 96), .q2)  // 91 + 8 > 96 → fall back to q2
        XCTAssertTrue(flashQuantFits(.q4, ramGiB: 512))
        XCTAssertFalse(flashQuantFits(.q4, ramGiB: 128))  // 153 + 8 > 128
    }
}
