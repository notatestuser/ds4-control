import XCTest

@testable import DS4Control

/// Records each launch's onExit so a test can replay a *stale* one. `terminate` is a no-op
/// (unlike FakeRunner it does not auto-fire onExit), modelling the real runner where the
/// SIGTERM'd process's termination handler fires asynchronously, after the relaunch.
private final class CapturingRunner: ProcessRunner {
    var isRunning = false
    private(set) var launches = 0
    private(set) var exits: [@Sendable (Int32) -> Void] = []
    func launch(
        executable: URL, args: [String], cwd: URL, env: [String: String],
        onStderrLine: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        launches += 1
        isRunning = true
        exits.append(onExit)
    }
    func terminate(graceSeconds: Double) { isRunning = false }
}

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

    /// A retry SIGTERMs the in-flight download; its onExit(15) lands *after* the new
    /// download started. The generation guard must drop that stale callback so it can't
    /// clobber the fresh .downloading state with a false "exit 15".
    func testStaleExitDoesNotClobberRestartedDownload() throws {
        let dl = CapturingRunner()
        let s = SupervisorService(ds4Dir: try makeDir(), runner: CapturingRunner(), downloadRunner: dl)

        s.download(variant: .flash)
        XCTAssertEqual(s.state, .downloading)
        XCTAssertEqual(dl.launches, 1)

        s.retryDownload(variant: .flash)  // terminate + relaunch; generation bumps to 2
        XCTAssertEqual(s.state, .downloading)
        XCTAssertEqual(dl.launches, 2)

        dl.exits[0](15)  // stale exit from the killed (gen-1) process
        XCTAssertEqual(s.state, .downloading, "stale exit-15 must not clobber the restarted download")

        dl.exits[1](0)  // the live (gen-2) download finishes
        XCTAssertEqual(s.state, .idle)
    }

    /// downloadProcessLive (drives the spinner) is true while the owned process runs and
    /// clears the moment it exits.
    func testProcessLiveTracksOwnedProcess() throws {
        let dl = CapturingRunner()
        let s = SupervisorService(ds4Dir: try makeDir(), runner: CapturingRunner(), downloadRunner: dl)

        s.download(variant: .flash)
        XCTAssertTrue(s.downloadProcessLive, "spinner should show once the process launched")

        dl.exits[0](0)  // process exits
        XCTAssertFalse(s.downloadProcessLive, "spinner must clear when the process exits")
    }

    /// Abort kills the download and returns to idle; the killed process's stale exit must
    /// not resurrect an error state.
    func testCancelDownloadReturnsToIdle() throws {
        let dl = CapturingRunner()
        let s = SupervisorService(ds4Dir: try makeDir(), runner: CapturingRunner(), downloadRunner: dl)

        s.download(variant: .flash)
        s.cancelDownload()
        XCTAssertEqual(s.state, .idle)
        XCTAssertFalse(s.downloadProcessLive)
        XCTAssertNil(s.download)

        dl.exits[0](15)  // stale exit from the aborted process
        XCTAssertEqual(s.state, .idle, "aborted download's stale exit must not flip back to .error")
    }
}
