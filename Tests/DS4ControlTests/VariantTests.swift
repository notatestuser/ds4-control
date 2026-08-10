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
        XCTAssertEqual(Quant.for(.pro, flashQuant: .q2q4).arg, "pro-q2-imatrix")  // Pro ignores flashQuant
        XCTAssertEqual(Quant.for(.flash, flashQuant: .q4).arg, "q4-imatrix")
        XCTAssertEqual(Quant.for(.flash, flashQuant: .q2).arg, "q2-imatrix")
        XCTAssertEqual(Quant.for(.flash, flashQuant: .q2q4).arg, "q2-q4-imatrix")
        XCTAssertEqual(Quant.for(.flash, flashQuant: .q8).arg, "q8")  // locally built, no upstream target
    }
    func testGgufFilenames() {
        XCTAssertEqual(
            Quant.for(.pro, flashQuant: .q2q4).ggufFilename,
            "DeepSeek-V4-Pro-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-Instruct-imatrix.gguf")
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
        // q8_0 experts, not q8_K: ds4's loader (`tensor_is_routed_expert_type`) rejects q8_K as a
        // routed expert storage type, so a q8_K build cannot be started at all.
        // Deliberately NO `-imatrix`: q8_0 discards it, as do the F16/Q8 tensors around it.
        XCTAssertEqual(
            Quant.for(.flash, flashQuant: .q8).ggufFilename,
            "DeepSeek-V4-Flash-Q8Experts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-0731.gguf"
        )
        XCTAssertFalse(Quant.for(.flash, flashQuant: .q8).ggufFilename.contains("imatrix"))
        XCTAssertFalse(Quant.for(.flash, flashQuant: .q8).ggufFilename.contains("Q8KExperts"))
        // Only the expert term differs from q4-imatrix — every other tensor family is carried
        // over from that template, so the rest of the name must match exactly.
        XCTAssertEqual(
            Quant.for(.flash, flashQuant: .q8).ggufFilename
                .replacingOccurrences(of: "Q8Experts", with: "Q4KExperts")
                .replacingOccurrences(of: "chat-v2-0731", with: "chat-v2-imatrix-0731"),
            Quant.for(.flash, flashQuant: .q4).ggufFilename)
    }
    func testLegacyPreviewFilenames() {
        XCTAssertEqual(Quant.legacyPreviewFilenames.count, 3)
        for q in [Quant.q2Imatrix, .q2q4Imatrix, .q4Imatrix] {
            XCTAssertFalse(Quant.legacyPreviewFilenames.contains(q.ggufFilename))  // no overlap with 0731 names
        }
    }
    func testWeights() {
        XCTAssertEqual(Quant.for(.pro, flashQuant: .q2q4).weightsGiB, 432, accuracy: 1)
        XCTAssertEqual(Quant.for(.flash, flashQuant: .q4).weightsGiB, 153, accuracy: 1)
        XCTAssertEqual(Quant.for(.flash, flashQuant: .q2).weightsGiB, 81, accuracy: 1)
        XCTAssertEqual(Quant.for(.flash, flashQuant: .q2q4).weightsGiB, 91, accuracy: 1)
        XCTAssertEqual(Quant.for(.flash, flashQuant: .q8).weightsGiB, 282.33, accuracy: 0.5)
    }
    func testFlashQuant() {
        XCTAssertEqual(FlashQuant.allCases, [.q2, .q2q4, .q4, .q8])  // smallest → largest (picker order)
        XCTAssertEqual(FlashQuant.q2q4.rawValue, "q2-q4-imatrix")
        XCTAssertEqual(FlashQuant.q2.quant, .q2Imatrix)
        XCTAssertEqual(FlashQuant.q2q4.quant, .q2q4Imatrix)
        XCTAssertEqual(FlashQuant.q4.quant, .q4Imatrix)
        XCTAssertEqual(FlashQuant.q8.quant, .q8Experts)
        XCTAssertEqual(FlashQuant.q2q4.label, "0731-q2-q4-imatrix · ~91 GiB")  // 0731 generation + resident size
        XCTAssertEqual(FlashQuant.q8.label, "0731-q8 · ~282 GiB")
    }
    func testFlashQuantFitAndDefault() {
        XCTAssertEqual(defaultFlashQuant(ramGiB: 512), .q2q4)  // requested default fits
        XCTAssertEqual(defaultFlashQuant(ramGiB: 96), .q2)  // 91 + 8 > 96 → fall back to q2
        XCTAssertTrue(flashQuantFits(.q4, ramGiB: 512))
        XCTAssertFalse(flashQuantFits(.q4, ramGiB: 128))  // 153 + 15.66 KV + 8 > 128
        XCTAssertTrue(flashQuantFits(.q8, ramGiB: 512))
        XCTAssertFalse(flashQuantFits(.q8, ramGiB: 256))
        XCTAssertNotEqual(defaultFlashQuant(ramGiB: 512), .q8)  // never auto-selected
    }

    /// The gate must include the KV cache the quant will actually run with, not just its weights.
    /// q8 is 282.33 GiB of weights, and `defaultCtx` gives Flash the full 1M window above 128 GiB —
    /// 15.66 GiB of KV. Weights + 8 alone said 290.33, so a 291–305 GiB machine used to pass the
    /// picker and then fail to launch.
    func testFlashQuantFitAccountsForKVCache() {
        let need = Quant.q8Experts.weightsGiB + kvGiB(variant: .flash, ctx: 1_000_000) + 8
        XCTAssertEqual(need, 306.0, accuracy: 0.5)
        XCTAssertFalse(flashQuantFits(.q8, ramGiB: 305), "weights+reserve alone would have passed this")
        XCTAssertTrue(flashQuantFits(.q8, ramGiB: 307))
        // KV at the 1M default is the measured ~15.7 GiB, not a guess.
        XCTAssertEqual(kvGiB(variant: .flash, ctx: 1_000_000), 15.66, accuracy: 0.05)
        // Smaller quants keep their existing verdicts: q2 still fits the 96 GiB floor, where
        // defaultCtx drops to 393K (6.16 GiB of KV) rather than 1M.
        XCTAssertTrue(flashQuantFits(.q2, ramGiB: 96))
        XCTAssertEqual(defaultFlashQuant(ramGiB: 96), .q2)
    }
}
