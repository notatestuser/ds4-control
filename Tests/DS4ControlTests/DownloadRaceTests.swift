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

    /// Drain the main actor for a generous WALL-CLOCK budget so any already-scheduled (or about-to-be
    /// scheduled) main-actor hop has every chance to land before a *negative* assertion runs.
    ///
    /// The stale-completion/stale-failure tests prove a negative — that an erroneous
    /// `completeDownload(gen1)` / `failDownload(gen1)` hop never flips state. Its arrival is owned by
    /// the off-main download `Task` (it enqueues the hop only *after* the resumed fetch returns/throws),
    /// so there is no production-free synchronization point the test can await exactly. A bounded
    /// yield COUNT (the old `for _ in 0..<200 { Task.yield() }`) is fragile: it depends on the off-main
    /// continuation chain finishing within N CPU yields. A wall-clock drain instead gives that chain
    /// real TIME to resume off-main, reach `Self.onMain`, enqueue the hop, and let the main actor's FIFO
    /// queue run it — the hop the reviewer measured landing in microseconds gets ~half a second here.
    /// Each iteration both yields (drains ready main-actor work) and sleeps (lets off-main work run).
    private func drainMainActor() async {
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)  // 1 ms — lets the off-main tail make progress
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

    /// A stale *completion* from a superseded download must be dropped by the generation guard. The
    /// first fetch (gen1) suspends on a continuation the test controls; the second (gen2, started by
    /// retry) never returns. We resume gen1 so its fetch RETURNS normally and its Task hops to main to
    /// call `completeDownload(gen1)` — but `downloadGeneration` was bumped to gen2 by retry, so the
    /// `completeDownload` guard must DROP it: state STAYS `.downloading`, never flipping to `.idle`/100%.
    /// Removing `downloadGeneration += 1` from `download()` (or the gen guard in `completeDownload`)
    /// makes the stale completion win and fails this. We rendezvous on `box.gen1Resumed` (a condition
    /// poll, proving the stale path ran) then `drainMainActor()` (a wall-clock budget letting the
    /// erroneous hop land) — see those helpers for why a fixed yield COUNT was replaced.
    func testStaleCompletionDroppedAfterRetry() async throws {
        let box = ContinuationBox()
        let s = SupervisorService(
            ds4Dir: try makeDir(), runner: NoopRunner(), fetchFile: box.gen1ReturnsFetch)
        s.download(variant: .flash, flashQuant: .q2q4)  // gen1: suspends on the stored continuation
        XCTAssertEqual(s.state, .downloading)
        await until { box.firstInvoked }  // gen1's fetch is parked on the continuation

        s.retryDownload(variant: .flash, flashQuant: .q2q4)  // cancels gen1's task, starts gen2 (forever)
        XCTAssertEqual(s.state, .downloading)

        box.resumeFirst()  // gen1's fetch RETURNS → its Task calls completeDownload(gen1), now stale
        // Prove the stale path actually ran (not a vacuous pass): wait until gen1's fetch resumed past
        // its continuation, then drain the main actor over a wall-clock budget so the erroneous
        // completeDownload(gen1) hop has every chance to land. If the generation guard failed, state
        // would flip to .idle / pct 100; it must not.
        await until { box.gen1Resumed }
        await drainMainActor()
        XCTAssertEqual(s.state, .downloading, "a stale completion must be dropped by the generation guard")
        XCTAssertTrue(s.downloadProcessLive, "gen2 is still in flight — the stale gen1 completion is dropped")
        XCTAssertEqual(s.download?.file, Quant.q2q4Imatrix.ggufFilename, "gen2's download remains the live one")
        s.cancelDownload()
    }

    /// The failure-path sibling of `testStaleCompletionDroppedAfterRetry`: after retry, gen1's fetch
    /// THROWS once resumed → its Task calls `failDownload(gen1)`, which the generation guard must DROP,
    /// so state must NOT become `.error` — it stays `.downloading` (gen2 still in flight).
    func testStaleFailureDroppedAfterRetry() async throws {
        let box = ContinuationBox()
        let s = SupervisorService(
            ds4Dir: try makeDir(), runner: NoopRunner(), fetchFile: box.gen1ThrowsFetch)
        s.download(variant: .flash, flashQuant: .q2q4)  // gen1: suspends on the stored continuation
        XCTAssertEqual(s.state, .downloading)
        await until { box.firstInvoked }

        s.retryDownload(variant: .flash, flashQuant: .q2q4)  // cancels gen1, starts gen2 (forever)
        XCTAssertEqual(s.state, .downloading)

        box.resumeFirst()  // gen1's fetch THROWS → its Task calls failDownload(gen1), now stale
        // Same discipline as the completion sibling: confirm gen1's fetch resumed (the stale failure
        // path is in flight), then drain the main actor so failDownload(gen1) has every chance to land.
        // The generation guard must drop it: state stays .downloading, never .error.
        await until { box.gen1Resumed }
        await drainMainActor()
        if case .error = s.state { XCTFail("a stale failure must be dropped by the generation guard") }
        XCTAssertEqual(s.state, .downloading)
        XCTAssertTrue(s.downloadProcessLive, "gen2 is still in flight — the stale gen1 failure is dropped")
        XCTAssertEqual(s.download?.file, Quant.q2q4Imatrix.ggufFilename, "gen2's download remains the live one")
        s.cancelDownload()
    }
}

/// Controllable fetch backing the generation-guard tests. The FIRST fetch invocation parks on a
/// stored continuation the test resumes on demand (so gen1 finishes deterministically *after* a
/// retry bumps the generation); every later invocation (gen2) suspends forever. `@unchecked
/// Sendable`: the continuation is set on the first call and read once by `resumeFirst`, both on the
/// main actor in these `@MainActor` tests, so there's no concurrent access.
private final class ContinuationBox: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var firstInvoked = false
    /// Flips once gen1's fetch has been resumed and run past the continuation — i.e. the stale
    /// `completeDownload`/`failDownload` path is now ON ITS WAY to the main actor. Polling this before
    /// the negative assertion proves the test actually EXERCISED the stale path (it isn't passing
    /// vacuously because the fetch never resumed). Same single-writer/cross-read discipline as
    /// `firstInvoked`. For the throwing variant it is set before the throw so it flips in both cases.
    private(set) var gen1Resumed = false
    private var invocations = 0

    /// gen1 returns normally on resume; gen2+ suspend forever.
    var gen1ReturnsFetch: SupervisorService.FetchFile {
        { _, _, _, _, _ in try await self.park(throwOnResume: false) }
    }
    /// gen1 throws on resume; gen2+ suspend forever.
    var gen1ThrowsFetch: SupervisorService.FetchFile {
        { _, _, _, _, _ in try await self.park(throwOnResume: true) }
    }

    private func park(throwOnResume: Bool) async throws {
        invocations += 1
        if invocations > 1 {
            try await Task.sleep(nanoseconds: 600_000_000_000)  // gen2: never returns
            return
        }
        firstInvoked = true
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.continuation = c
        }
        gen1Resumed = true  // the stale path is now in flight toward the main actor
        if throwOnResume { throw HFDownloader.Failure.http(503) }
    }

    /// Resume the parked gen1 fetch so it returns (or throws, per the variant).
    func resumeFirst() {
        let c = continuation
        continuation = nil
        c?.resume()
    }
}
