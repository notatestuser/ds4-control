import XCTest
@testable import DS4Control

final class VariantTests: XCTestCase {
    func testKVBytesPerToken() {
        XCTAssertEqual(Variant.pro.kvBytesPerToken, 39_040)   // 61 layers × 640
        XCTAssertEqual(Variant.flash.kvBytesPerToken, 27_520) // 43 layers × 640
    }
    func testCtxCeiling() {
        XCTAssertEqual(Variant.pro.ctxCeiling, 1_000_000)
        XCTAssertEqual(Variant.flash.ctxCeiling, 393_216)
    }
    func testQuantSelection() {
        XCTAssertEqual(Quant.for(.pro, ramGiB: 600).arg, "pro-imatrix")
        XCTAssertEqual(Quant.for(.flash, ramGiB: 300).arg, "q4-imatrix")
        XCTAssertEqual(Quant.for(.flash, ramGiB: 128).arg, "q2-imatrix")
    }
    func testGgufFilenames() {
        XCTAssertEqual(Quant.for(.pro, ramGiB: 600).ggufFilename,
            "DeepSeek-V4-Pro-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-Instruct-imatrix.gguf")
        XCTAssertEqual(Quant.for(.flash, ramGiB: 300).ggufFilename,
            "DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-imatrix.gguf")
        XCTAssertEqual(Quant.for(.flash, ramGiB: 128).ggufFilename,
            "DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix.gguf")
    }
    func testWeights() {
        XCTAssertEqual(Quant.for(.pro, ramGiB: 600).weightsGiB, 432, accuracy: 1)
        XCTAssertEqual(Quant.for(.flash, ramGiB: 300).weightsGiB, 153, accuracy: 1)
        XCTAssertEqual(Quant.for(.flash, ramGiB: 128).weightsGiB, 81, accuracy: 1)
    }
}
