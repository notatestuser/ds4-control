import XCTest

@testable import DS4Control

/// No-op runner for the server slot — this file only exercises downloads.
private final class SupportNoopRunner: ProcessRunner {
    var isRunning = false
    func launch(
        executable: URL, args: [String], cwd: URL, env: [String: String],
        onStderrLine: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable (Int32) -> Void
    ) throws {}
    func terminate(graceSeconds: Double) {}
}

/// The DSpark support GGUF downloads on its OWN track: it must never enter `ServerState.downloading`
/// (which would block Start for a ~5.6 GiB accessory), but it must still park behind a model
/// download so the two don't split bandwidth. These tests inject fake fetches — no network.
@MainActor
final class SupportDownloadTests: XCTestCase {
    /// A fetch that never returns — the download stays in flight.
    private static let pending: SupervisorService.FetchFile = { _, _, _, _, _ in
        try await Task.sleep(nanoseconds: 600_000_000_000)
    }
    /// Reports half the file, then parks — so progress is observable while still "in flight".
    private static let halfway: SupervisorService.FetchFile = { _, _, _, _, progress in
        progress(DSparkSupport.bytes / 2, DSparkSupport.bytes)
        try await Task.sleep(nanoseconds: 600_000_000_000)
    }
    /// Writes the destination file and returns, like a real completed download.
    private static let completing: SupervisorService.FetchFile = { file, dir, _, _, progress in
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent(file).path, contents: Data("gguf".utf8))
        progress(DSparkSupport.bytes, DSparkSupport.bytes)
    }

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

    private func until(_ cond: @escaping () -> Bool) async {
        for _ in 0..<400 {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Independence from the server state machine

    /// The whole point of the separate track: downloading the support model leaves the app idle, so
    /// Start/Stop and the popup stay usable.
    func testSupportDownloadDoesNotEnterDownloadingState() throws {
        let s = SupervisorService(ds4Dir: try makeDir(), runner: SupportNoopRunner(), fetchFile: Self.pending)
        s.downloadDSparkSupport()
        XCTAssertTrue(s.supportDownloadLive)
        XCTAssertEqual(s.supportDownload?.file, DSparkSupport.ggufFilename)
        XCTAssertEqual(s.state, .idle, "the model-download state machine must be untouched")
        XCTAssertNil(s.download)
        s.cancelDSparkSupportDownload()
    }

    func testSupportProgressPublishesPercentAndBytes() async throws {
        let s = SupervisorService(ds4Dir: try makeDir(), runner: SupportNoopRunner(), fetchFile: Self.halfway)
        s.downloadDSparkSupport()
        await until { (s.supportDownload?.pct ?? 0) > 0 }
        XCTAssertEqual(s.supportDownload?.pct ?? 0, 50, accuracy: 0.01)
        XCTAssertEqual(s.supportDownload?.receivedBytes, DSparkSupport.bytes / 2)
        XCTAssertEqual(s.state, .idle)
        s.cancelDSparkSupportDownload()
    }

    func testSupportDownloadCompletes() async throws {
        let s = SupervisorService(
            ds4Dir: try makeDir(), runner: SupportNoopRunner(), fetchFile: Self.completing)
        s.downloadDSparkSupport()
        await until { !s.supportDownloadLive }
        XCTAssertFalse(s.supportDownloadLive)
        XCTAssertNil(s.supportDownload, "the row switches to the downloaded state, not a stuck 100% bar")
        XCTAssertNil(s.supportDownloadError)
        XCTAssertTrue(s.isDSparkSupportDownloaded())
    }

    /// A failure surfaces on the support track's own error field — it must NOT put the app into
    /// `.error`, which would make an accessory download look like a broken server.
    func testSupportDownloadFailureIsIsolated() async throws {
        let s = SupervisorService(
            ds4Dir: try makeDir(), runner: SupportNoopRunner(),
            fetchFile: { _, _, _, _, _ in throw HFDownloader.Failure.http(503) })
        s.downloadDSparkSupport()
        await until { s.supportDownloadError != nil }
        XCTAssertEqual(s.supportDownloadError, "HTTP 503")
        XCTAssertFalse(s.supportDownloadLive)
        XCTAssertEqual(s.state, .idle)
    }

    /// Cancel is a deliberate stop, so it discards the partial — the same contract as
    /// `cancelDownload()`. (Quitting mid-download keeps both files so the next launch resumes.)
    func testCancelDeletesPartAndSidecar() throws {
        let dir = try makeDir()
        let gguf = dir.appendingPathComponent("gguf")
        let part = gguf.appendingPathComponent(DSparkSupport.ggufFilename + ".part")
        let sidecar = gguf.appendingPathComponent(DSparkSupport.ggufFilename + ".part.dl")
        try Data(count: 16).write(to: part)
        try Data(count: 16).write(to: sidecar)

        let s = SupervisorService(ds4Dir: dir, runner: SupportNoopRunner(), fetchFile: Self.pending)
        s.downloadDSparkSupport()
        XCTAssertTrue(s.supportDownloadLive)
        s.cancelDSparkSupportDownload()

        XCTAssertFalse(s.supportDownloadLive)
        XCTAssertNil(s.supportDownload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
    }

    // MARK: - Serialisation with the model download

    /// A model download parks a live support download (keeping its partial), and the support
    /// download re-arms once the model download ends — here via cancel.
    func testModelDownloadParksSupportDownloadAndReArms() throws {
        let dir = try makeDir()
        let part = dir.appendingPathComponent("gguf/" + DSparkSupport.ggufFilename + ".part")
        try Data(count: 16).write(to: part)

        let s = SupervisorService(ds4Dir: dir, runner: SupportNoopRunner(), fetchFile: Self.pending)
        s.downloadDSparkSupport()
        XCTAssertTrue(s.supportDownloadLive)

        s.download(variant: .flash, flashQuant: .q2q4)  // the model download claims the pipe
        XCTAssertEqual(s.state, .downloading)
        XCTAssertFalse(s.supportDownloadLive, "the support download pauses")
        XCTAssertTrue(s.supportDownloadDeferred)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: part.path),
            "a park is a pause, not a cancel — the partial must survive so it can resume")

        s.cancelDownload()  // model download ends → the parked one resumes
        XCTAssertEqual(s.state, .idle)
        XCTAssertTrue(s.supportDownloadLive)
        XCTAssertFalse(s.supportDownloadDeferred)
        s.cancelDSparkSupportDownload()
    }

    /// Requesting the support download while a model download is already running parks it straight
    /// away rather than running both at once.
    func testRequestDuringModelDownloadDefers() throws {
        let s = SupervisorService(ds4Dir: try makeDir(), runner: SupportNoopRunner(), fetchFile: Self.pending)
        s.download(variant: .flash, flashQuant: .q2q4)
        XCTAssertEqual(s.state, .downloading)

        s.downloadDSparkSupport()
        XCTAssertFalse(s.supportDownloadLive)
        XCTAssertTrue(s.supportDownloadDeferred)
        s.cancelDownload()
        XCTAssertTrue(s.supportDownloadLive, "re-armed once the pipe is free")
        s.cancelDSparkSupportDownload()
    }

    // MARK: - Store

    func testDownloadNoOpsWhenAlreadyOnDisk() throws {
        let dir = try makeDir()
        try Data(count: 4).write(
            to: dir.appendingPathComponent("gguf/" + DSparkSupport.ggufFilename))
        let s = SupervisorService(ds4Dir: dir, runner: SupportNoopRunner(), fetchFile: Self.pending)
        s.downloadDSparkSupport()
        XCTAssertFalse(s.supportDownloadLive)
        XCTAssertNil(s.supportDownload)
    }

    func testRemoveDeletesFileAndPartials() throws {
        let dir = try makeDir()
        let gguf = dir.appendingPathComponent("gguf")
        for name in [
            DSparkSupport.ggufFilename, DSparkSupport.ggufFilename + ".part",
            DSparkSupport.ggufFilename + ".part.dl",
        ] {
            try Data(count: 8).write(to: gguf.appendingPathComponent(name))
        }
        let s = SupervisorService(ds4Dir: dir, runner: SupportNoopRunner())
        XCTAssertTrue(s.isDSparkSupportDownloaded())
        XCTAssertTrue(s.removeDSparkSupport())
        XCTAssertFalse(s.isDSparkSupportDownloaded())
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: gguf.appendingPathComponent(DSparkSupport.ggufFilename + ".part").path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: gguf.appendingPathComponent(DSparkSupport.ggufFilename + ".part.dl").path))
        XCTAssertFalse(s.removeDSparkSupport(), "nothing left to remove")
    }

    /// A resumable partial left by a prior session resumes at launch.
    func testResumeInFlightSupportDownload() throws {
        let dir = try makeDir()
        try Data(count: 4096).write(
            to: dir.appendingPathComponent("gguf/" + DSparkSupport.ggufFilename + ".part"))
        let s = SupervisorService(ds4Dir: dir, runner: SupportNoopRunner(), fetchFile: Self.pending)
        s.resumeInFlightSupportDownloadIfAny()
        XCTAssertTrue(s.supportDownloadLive)
        s.cancelDSparkSupportDownload()
    }

    func testResumeNoOpWithoutPartial() throws {
        let s = SupervisorService(ds4Dir: try makeDir(), runner: SupportNoopRunner(), fetchFile: Self.pending)
        s.resumeInFlightSupportDownloadIfAny()
        XCTAssertFalse(s.supportDownloadLive)
    }

    // MARK: - The --mtp launch argument

    /// `dsparkSupportArg` is the single gate every launch site uses: it must return nil for every
    /// configuration ds4 can't actually speculate in, and nil when the file isn't there — passing
    /// `--dspark` with an unreadable `--mtp FILE` fails engine open outright.
    func testSupportArgRequiresFileOnDisk() throws {
        let dir = try makeDir()
        let s = SupervisorService(ds4Dir: dir, runner: SupportNoopRunner())
        XCTAssertNil(s.dsparkSupportArg(enabled: true, variant: .flash, sessions: 1))

        try Data(count: 4).write(to: dir.appendingPathComponent("gguf/" + DSparkSupport.ggufFilename))
        XCTAssertEqual(
            s.dsparkSupportArg(enabled: true, variant: .flash, sessions: 1)?.lastPathComponent,
            DSparkSupport.ggufFilename)
        XCTAssertNil(s.dsparkSupportArg(enabled: false, variant: .flash, sessions: 1))
        XCTAssertNil(s.dsparkSupportArg(enabled: true, variant: .pro, sessions: 1))
        XCTAssertNil(s.dsparkSupportArg(enabled: true, variant: .flash, sessions: 4))
    }
}
