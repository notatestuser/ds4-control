import XCTest

/// Source-level regression guard: a failed `Process.run()` never reaches the
/// `terminationHandler` that stops the stderr reader, and the reader → FileHandle →
/// readability-handler cycle keeps the pipe's descriptors alive. The throwing launch must
/// stop the reader before propagating.
final class ProcessRunnerSourceTests: XCTestCase {
    func testFailedLaunchStopsStderrReaderBeforeRethrowing() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/DS4Control/Services/ProcessRunner.swift"),
            encoding: .utf8)

        let runCall = try XCTUnwrap(src.range(of: "try p.run()"))
        let catchBlock = try XCTUnwrap(
            src.range(of: "} catch {", range: runCall.upperBound..<src.endIndex),
            "launch must handle a throwing Process.run()")
        XCTAssertNotNil(
            src.range(of: "reader.stop()", range: catchBlock.upperBound..<src.endIndex),
            "the launch failure path must stop the stderr reader before propagating")
        // The refused-launch guard must sit inside the same do/catch: its throw skips
        // `terminationHandler` too, so the reader would leak with it.
        let doStart = try XCTUnwrap(
            src.range(of: "do {", options: .backwards, range: src.startIndex..<runCall.lowerBound))
        let guardThrow = try XCTUnwrap(src.range(of: "ProcessRunnerError.alreadyRunning"))
        XCTAssertLessThan(doStart.lowerBound, guardThrow.lowerBound, "the guard must be inside the do")
        XCTAssertLessThan(guardThrow.lowerBound, catchBlock.lowerBound, "the guard's throw must be caught")
    }
}
