import XCTest
@testable import DS4Control

final class ModelTests: XCTestCase {
    func testAllCasesAndLabels() {
        XCTAssertEqual(Model.allCases, [.v4Pro, .v4FlashQ2, .v4FlashQ2Q4, .v4FlashQ4, .lagunaS21])
        XCTAssertEqual(Model.v4Pro.displayName, "V4 Pro")
        XCTAssertEqual(Model.v4FlashQ2Q4.displayName, "V4 Flash")
        XCTAssertEqual(Model.lagunaS21.displayName, "Laguna S 2.1")
        XCTAssertEqual(Model.v4FlashQ4.label, "V4 Flash · ~153 GiB")
        XCTAssertEqual(Model.lagunaS21.label, "Laguna S 2.1 · ~45 GiB")
    }
    func testModelIds() {
        XCTAssertEqual(Model.v4Pro.modelId, "deepseek-v4-pro")
        XCTAssertEqual(Model.v4FlashQ2Q4.modelId, "deepseek-v4-flash")
        XCTAssertEqual(Model.lagunaS21.modelId, "laguna-s-2.1")
    }
    func testQuantMappingAndCapabilities() {
        XCTAssertEqual(Model.v4FlashQ2Q4.quant, .q2q4Imatrix)
        XCTAssertNil(Model.lagunaS21.quant)  // no DS4F quant
        XCTAssertTrue(Model.v4FlashQ2Q4.supportsSSDStreaming)
        XCTAssertFalse(Model.lagunaS21.supportsSSDStreaming)  // ds4 hard gate
        XCTAssertTrue(Model.v4FlashQ2Q4.supportsThinkingModes)
        XCTAssertFalse(Model.lagunaS21.supportsThinkingModes)  // v1: native reasoning, no picker
    }
    func testLagunaDownloadAndSizeFacts() {
        XCTAssertEqual(Model.lagunaS21.weightsGiB, 44.95, accuracy: 0.01)
        XCTAssertEqual(Model.lagunaS21.downloadRepo, "antirez/Laguna-S-2.1-GGUF")
        XCTAssertEqual(Model.lagunaS21.downloadRevision, "main")
        XCTAssertEqual(
            Model.lagunaS21.ggufFilename,
            "laguna-s-2.1-RoutedQ2_K-Last27Q3_K.gguf")
        XCTAssertNil(Model.lagunaS21.routedExpertGiB)  // SSD streaming N/A
    }
    func testCtxCeilingAndPowerCap() {
        XCTAssertEqual(Model.lagunaS21.ctxCeiling, 262_144)  // GGUF laguna.context_length
        XCTAssertEqual(Model.v4FlashQ2Q4.ctxCeiling, 1_000_000)
        XCTAssertFalse(Model.lagunaS21.supportsPowerCap)  // ds4 standard-graph-only gate
        XCTAssertTrue(Model.v4FlashQ2Q4.supportsPowerCap)
    }
}
