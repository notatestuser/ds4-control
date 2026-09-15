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

    func testV41HarnessStreamsAndGatesAt128GiB() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let harness = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/flash41-mem-harness.sh"),
            encoding: .utf8)

        XCTAssertTrue(harness.contains("DeepSeek-V4.1-Flash-Q2.gguf"))
        XCTAssertTrue(harness.contains("--ssd-streaming"))
        XCTAssertTrue(harness.contains("--power 100"))
        XCTAssertTrue(harness.contains("deepseek-v4.1-flash"))
        XCTAssertTrue(harness.contains("LIMIT_GIB=${DS41_LIMIT_GIB:-128}"))
        XCTAssertTrue(harness.contains("resident model"))
        XCTAssertTrue(harness.contains("planned"))
    }

    /// A stalled ds4-server must not hang the sampling loop forever (curl deadline), and an
    /// interrupt must not leak the server process, temp files, or the disk-KV dir (traps).
    func testV41HarnessBoundsInferenceAndCleansUpOnSignals() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let harness = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/flash41-mem-harness.sh"),
            encoding: .utf8)

        // Configurable inference deadline following the harness env conventions.
        XCTAssertTrue(harness.contains("INFERENCE_TIMEOUT_S=${DS41_INFERENCE_TIMEOUT_S:-900}"))

        // The deadline must sit on the INFERENCE curl itself — any other command carrying
        // --max-time must not satisfy this while the request to /v1/chat/completions
        // stays unbounded.
        let lines = harness.components(separatedBy: .newlines)
        guard let curlStart = lines.firstIndex(where: { $0.contains("curl -fsS") }) else {
            return XCTFail("harness has no inference curl command")
        }
        var curlEnd = curlStart
        while curlEnd + 1 < lines.count, !lines[curlEnd].hasSuffix("&") { curlEnd += 1 }
        let inferenceCurl = lines[curlStart...curlEnd].joined(separator: " ")
        XCTAssertTrue(
            inferenceCurl.contains("/v1/chat/completions"),
            "extracted command is not the inference request")
        XCTAssertTrue(
            inferenceCurl.contains("--max-time \"$INFERENCE_TIMEOUT_S\""),
            "inference curl must carry the --max-time deadline")

        // Signal/exit traps tear down the server, temp files, and the KV scratch dir.
        XCTAssertTrue(harness.contains("cleanup() {"))
        XCTAssertTrue(harness.contains("trap cleanup EXIT"))
        XCTAssertTrue(harness.contains("trap 'cleanup; exit 1' INT TERM HUP"))
    }

    /// Peak RSS must cover the whole server lifetime — startup (model load, warm-weights)
    /// included, not just the inference window: the sampler runs in the readiness loop and
    /// the request loop.
    func testV41HarnessSamplesRssFromStartup() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let harness = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/flash41-mem-harness.sh"),
            encoding: .utf8)

        XCTAssertTrue(harness.contains("sample_rss() {"))
        let readiness = try XCTUnwrap(harness.range(of: "while ! grep -q \"listening on http://\""))
        let request = try XCTUnwrap(harness.range(of: "while kill -0 \"$cpid\""))
        XCTAssertTrue(
            harness[readiness.lowerBound..<request.lowerBound].contains("sample_rss"),
            "startup (readiness) must be sampled")
        let requestEnd = try XCTUnwrap(
            harness.range(of: "if ! wait \"$cpid\"", range: request.lowerBound..<harness.endIndex))
        XCTAssertTrue(
            harness[request.lowerBound..<requestEnd.lowerBound].contains("sample_rss"),
            "the inference window must be sampled")
    }

    /// The harness must cross-check ds4's live plan against the Feasibility mirror constant:
    /// the resident model equals ds41NonRoutedBytes (streaming) within the sampling tolerance.
    func testV41HarnessCrossChecksResidentAgainstMirror() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let harness = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/flash41-mem-harness.sh"),
            encoding: .utf8)

        XCTAssertTrue(harness.contains("ds41NonRoutedBytes"))
        XCTAssertTrue(harness.contains("RSS_COMPARISON_TOLERANCE_MIB/1024"))
    }
}
