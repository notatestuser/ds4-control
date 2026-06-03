import XCTest

@testable import DS4Control

/// No-op runner for the server slot — downloads no longer go through a `ProcessRunner`.
private final class NoopRunner: ProcessRunner {
    var isRunning = false
    func launch(
        executable: URL, args: [String], cwd: URL, env: [String: String],
        onStderrLine: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable (Int32) -> Void
    ) throws {}
    func terminate(graceSeconds: Double) {}
}

/// The download is now a native `Task` driving an injected `FetchFile`. These tests inject fakes
/// (no network) and assert the same observable contract: state transitions, the spinner flag, and
/// cancel/return-to-idle.
@MainActor
final class DownloadRaceTests: XCTestCase {
    private func makeDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("gguf"), withIntermediateDirectories: true)
        for f in ["ds4-server", "download_model.sh"] {
            let u = dir.appendingPathComponent(f)
            FileManager.default.createFile(atPath: u.path, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        }
        return dir
    }

    /// Spin (yielding the main actor) until `cond` holds or a short timeout — the native download
    /// finishes via an async Task hopping back to main.
    private func until(_ cond: @escaping () -> Bool) async {
        for _ in 0..<400 {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// A fetch that never returns — the download stays in flight.
    private let pending: SupervisorService.FetchFile = { _, _, _, _, _ in
        try await Task.sleep(nanoseconds: 600_000_000_000)
    }

    func testDownloadEntersDownloadingAndShowsSpinner() throws {
        let s = SupervisorService(ds4Dir: try makeDir(), runner: NoopRunner(), fetchFile: pending)
        s.download(variant: .flash, flashQuant: .q2q4)
        XCTAssertEqual(s.state, .downloading)
        XCTAssertTrue(s.downloadProcessLive, "spinner should show while the download task is in flight")
        XCTAssertEqual(s.download?.file, Quant.q2q4Imatrix.ggufFilename, "downloads the selected quant's file")
        s.cancelDownload()
    }

    func testSuccessfulDownloadGoesIdle() async throws {
        let s = SupervisorService(ds4Dir: try makeDir(), runner: NoopRunner(), fetchFile: { _, _, _, _, _ in })
        s.download(variant: .flash, flashQuant: .q2q4)
        await until { s.state == .idle }
        XCTAssertEqual(s.state, .idle)
        XCTAssertEqual(s.download?.pct, 100)
        XCTAssertFalse(s.downloadProcessLive, "spinner must clear when the download completes")
    }

    func testFailedDownloadGoesError() async throws {
        let s = SupervisorService(
            ds4Dir: try makeDir(), runner: NoopRunner(),
            fetchFile: { _, _, _, _, _ in throw HFDownloader.Failure.http(503) })
        s.download(variant: .flash, flashQuant: .q2q4)
        await until { if case .error = s.state { return true } else { return false } }
        guard case .error = s.state else { return XCTFail("expected .error, got \(s.state)") }
        XCTAssertFalse(s.downloadProcessLive)
    }

    func testCancelDownloadReturnsToIdle() throws {
        let s = SupervisorService(ds4Dir: try makeDir(), runner: NoopRunner(), fetchFile: pending)
        s.download(variant: .flash, flashQuant: .q2q4)
        s.cancelDownload()
        XCTAssertEqual(s.state, .idle)
        XCTAssertFalse(s.downloadProcessLive)
        XCTAssertNil(s.download)
    }

    /// A retry while a download is in flight must leave us .downloading (the cancelled prior task
    /// can't clobber state — it's cancelled, and a stale completion is dropped by the generation
    /// guard).
    func testRetryStaysDownloading() throws {
        let s = SupervisorService(ds4Dir: try makeDir(), runner: NoopRunner(), fetchFile: pending)
        s.download(variant: .flash, flashQuant: .q2q4)
        s.retryDownload(variant: .flash, flashQuant: .q2q4)
        XCTAssertEqual(s.state, .downloading)
        s.cancelDownload()
    }
}
