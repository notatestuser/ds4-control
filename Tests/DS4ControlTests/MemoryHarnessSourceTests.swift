import XCTest

final class MemoryHarnessSourceTests: XCTestCase {
    private func harnessSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/flash-mem-harness.sh"),
            encoding: .utf8)
    }

    func testHarnessExercisesAndValidatesContextFrontier() throws {
        let harness = try harnessSource()

        XCTAssertTrue(harness.contains("prompt_target=$((ctx - FRONTIER_MARGIN_TOKENS))"))
        XCTAssertTrue(harness.contains("printf \"<think>\""))
        XCTAssertTrue(harness.contains("prompt reached $prompt_tokens tokens, below frontier target"))
        XCTAssertTrue(harness.contains("indexer > 0"))
        XCTAssertFalse(harness.contains("Say hi in one word."))
    }

    func testDiskKVComparisonAllowsRSSSamplingTolerance() throws {
        let harness = try harnessSource()

        XCTAssertTrue(harness.contains("RSS_COMPARISON_TOLERANCE_MIB"))
        XCTAssertTrue(
            harness.contains("$disk_total_raw + $RSS_COMPARISON_TOLERANCE_MIB/1024"))
    }
}
