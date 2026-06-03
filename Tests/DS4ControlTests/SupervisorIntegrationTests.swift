import XCTest
import Combine
@testable import DS4Control

@MainActor
final class SupervisorIntegrationTests: XCTestCase {
    /// A fetch that never returns — keeps the download in flight without touching the network.
    private static let pending: SupervisorService.FetchFile = { _, _, _, _, _ in
        try await Task.sleep(nanoseconds: 600_000_000_000)
    }
    /// Stub `ds4-server` + `download_model.sh` so `validateDs4Dir()` passes.
    private func stubDs4(_ dir: URL) throws {
        for f in ["ds4-server", "download_model.sh"] {
            let u = dir.appendingPathComponent(f)
            FileManager.default.createFile(atPath: u.path, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        }
    }
    private func until(_ cond: @escaping () -> Bool) async {
        for _ in 0..<400 {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Seed a real sparse `<file>.part` preallocated to `total`, plus its `<file>.part.dl` bitmap
    /// sidecar with `completeChunks` chunks marked complete — exactly the resumable partial the real
    /// downloader leaves behind. The `ChunkBitmap` (which holds an open `FileHandle` to the sidecar)
    /// is created and dropped entirely WITHIN this function, so on return ARC releases it and the
    /// handle's deinit closes the fd: no open descriptor to `.part.dl` survives into the caller. That
    /// matters for the cancel test, whose `removeItem(.part.dl)` would otherwise race an open handle
    /// and leave a lingering directory entry on macOS (a build/optimizer-dependent false-red).
    private func seedResumablePartial(
        part: URL, total: Int64, chunkSize: Int64, completeChunks: Int
    ) throws {
        FileManager.default.createFile(atPath: part.path, contents: nil)
        let bitmap = try ChunkBitmap.loadOrCreate(
            partURL: part, total: total, chunkSize: chunkSize, seedContiguousBytes: 0)
        for i in 0..<completeChunks { try bitmap.markComplete(i) }
        let sizer = try FileHandle(forWritingTo: part)
        try sizer.truncate(atOffset: UInt64(total))
        try sizer.close()
    }

    /// Legacy `.incomplete` (hf-style) partial on disk → resume detects it via `downloadedBytes` and
    /// re-enters `.downloading`. (Live byte progress now comes from the downloader's `onProgress`
    /// callback, not an on-disk poll, so `Self.pending` — which never calls it — leaves `download` at
    /// the seeded 0; we assert the resume *triggered*, which is the legacy path's contract.)
    func testResumeResumesInFlightPartial() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let dl = dir.appendingPathComponent("gguf/.cache/huggingface/download")
        try FileManager.default.createDirectory(at: dl, withIntermediateDirectories: true)
        try stubDs4(dir)
        try Data(count: 5_000_000).write(to: dl.appendingPathComponent("h.incomplete"))
        let s = SupervisorService(ds4Dir: dir, runner: RealProcessRunner(), fetchFile: Self.pending)
        s.resumeInFlightDownloadIfAny(variant: .pro, flashQuant: .q2q4)  // a partial exists → resumes
        XCTAssertEqual(s.state, .downloading)
        XCTAssertEqual(s.download?.file, Quant.proImatrix.ggufFilename)  // resumes the Pro file
        XCTAssertTrue(s.downloadProcessLive)
        s.cancelDownload()
    }

    func testResumeNoOpWhenNoPartial() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("gguf"), withIntermediateDirectories: true)
        let s = SupervisorService(ds4Dir: dir, runner: RealProcessRunner())
        s.resumeInFlightDownloadIfAny(variant: .pro, flashQuant: .q2q4)
        XCTAssertEqual(s.state, .idle)
    }

    func testResumeNoOpWhenComplete() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let g = dir.appendingPathComponent("gguf")
        try FileManager.default.createDirectory(at: g, withIntermediateDirectories: true)
        try Data(count: 10).write(to: g.appendingPathComponent(Quant.proImatrix.ggufFilename))
        let s = SupervisorService(ds4Dir: dir, runner: RealProcessRunner())
        s.resumeInFlightDownloadIfAny(variant: .pro, flashQuant: .q2q4)
        XCTAssertEqual(s.state, .idle)
    }

    func testRetryStartsFreshDownload() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("gguf/.cache/huggingface/download"), withIntermediateDirectories: true)
        try stubDs4(dir)
        // Simulate a stuck partial, then retry from idle.
        try Data(count: 1024).write(
            to: dir.appendingPathComponent("gguf/.cache/huggingface/download/h.incomplete"))
        let s = SupervisorService(ds4Dir: dir, runner: RealProcessRunner(), fetchFile: Self.pending)
        s.retryDownload(variant: .pro, flashQuant: .q2q4)
        XCTAssertEqual(s.state, .downloading)
        XCTAssertNotNil(s.download)
        s.cancelDownload()
    }

    func testLoadedModelNamePrefersName() {
        let d = Data(#"{"object":"list","data":[{"id":"deepseek-v4-pro","name":"DeepSeek V4 Pro"}]}"#.utf8)
        XCTAssertEqual(loadedModelName(from: d), "DeepSeek V4 Pro")
    }
    func testLoadedModelNameFallsBackToId() {
        let d = Data(#"{"object":"list","data":[{"id":"deepseek-v4-flash"}]}"#.utf8)
        XCTAssertEqual(loadedModelName(from: d), "deepseek-v4-flash")
    }
    func testLoadedModelNameNilOnGarbage() {
        XCTAssertNil(loadedModelName(from: Data("not json".utf8)))
    }
    func testLoadedContextLengthReadsContextLength() {
        let d = Data(#"{"data":[{"id":"pro","context_length":1000000}]}"#.utf8)
        XCTAssertEqual(loadedContextLength(from: d), 1_000_000)
    }
    func testLoadedContextLengthFallsBackToTopProvider() {
        let d = Data(#"{"data":[{"id":"pro","top_provider":{"context_length":393216}}]}"#.utf8)
        XCTAssertEqual(loadedContextLength(from: d), 393_216)
    }
    func testLoadedContextLengthNilOnGarbage() {
        XCTAssertNil(loadedContextLength(from: Data("nope".utf8)))
    }

    func testResumeAttachesToRunningServer() throws {
        // Inject a deterministic probe — no live socket (nc fixtures are flaky on CI).
        let body = Data(
            #"{"object":"list","data":[{"id":"deepseek-v4-pro","name":"DeepSeek V4 Pro","context_length":1000000}]}"#
                .utf8)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = SupervisorService(ds4Dir: dir, runner: RealProcessRunner(), serverProbe: { _ in body })
        let ready = expectation(description: "attached ready")
        let token = s.$state.sink { if $0 == .ready { ready.fulfill() } }
        s.resumeRunningServerIfAny(port: 8251)
        wait(for: [ready], timeout: 5)
        token.cancel()
        XCTAssertEqual(s.activeModel, "DeepSeek V4 Pro")
        XCTAssertEqual(s.ctx, 1_000_000)  // adopted server's real context, not the 393_216 default
        s.stop()
    }

    func testResumeNoOpWhenNoServer() throws {
        // Probe returns nil (no server) → stays idle.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = SupervisorService(ds4Dir: dir, runner: RealProcessRunner(), serverProbe: { _ in nil })
        s.resumeRunningServerIfAny(port: 8251)
        let exp = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(s.state, .idle)
    }

    func testReachesReadyAgainstFakeServer() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = repoRoot.appendingPathComponent("Tests/Fixtures")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("gguf"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("fake-ds4-server.sh"), to: dir.appendingPathComponent("ds4-server"))
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("fake-download_model.sh"),
            to: dir.appendingPathComponent("download_model.sh"))
        for f in ["ds4-server", "download_model.sh"] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent(f).path)
        }
        // The supervisor resolves the gguf via Quant.for(.flash, flashQuant:); create the
        // file for the quant the test starts with (.q2q4) so the fixture matches.
        let hostQuant = Quant.for(.flash, flashQuant: .q2q4)
        let gg = dir.appendingPathComponent("gguf").appendingPathComponent(hostQuant.ggufFilename)
        FileManager.default.createFile(atPath: gg.path, contents: Data("gguf".utf8))

        let s = SupervisorService(ds4Dir: dir, runner: RealProcessRunner())
        s.start(variant: .flash, flashQuant: .q2q4, ctx: 250_000, port: 8137, power: nil)
        let ready = expectation(description: "ready")
        let token = s.$state.sink { if $0 == .ready { ready.fulfill() } }
        wait(for: [ready], timeout: 10)
        token.cancel()
        s.stop()
    }

    func testDownloadCompletesToIdle() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("gguf"), withIntermediateDirectories: true)
        try stubDs4(dir)
        let s = SupervisorService(ds4Dir: dir, runner: RealProcessRunner(), fetchFile: { _, _, _, _, _ in })
        s.download(variant: .flash, flashQuant: .q2q4)
        await until { s.state == .idle }
        XCTAssertEqual(s.state, .idle)
        XCTAssertEqual(s.download?.pct, 100)
    }

    /// Live downloaded-MB / % / speed display now updates from the native downloader's `onProgress`
    /// callback (the `.part` is sparse, so its file size is meaningless). The injected fake reports a
    /// growing `received` of a fixed `total`; we assert the published `download.receivedBytes` grows.
    func testDownloadStreamsProgressFromCallback() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("gguf"), withIntermediateDirectories: true)
        try stubDs4(dir)
        // Fetch that calls onProgress in growing steps (25/50/75/100 MB of a 100 MB total), with small
        // sleeps so the @download publisher observes the climb. No network, no disk writes.
        let total: Int64 = 100 * 1024 * 1024
        let s = SupervisorService(
            ds4Dir: dir, runner: RealProcessRunner(),
            fetchFile: { _, _, _, _, onProgress in
                for step in 1...4 {
                    try Task.checkCancellation()
                    onProgress(Int64(step) * 25 * 1024 * 1024, total)
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            })
        var seenBytes: [Int64] = []
        let token = s.$download.sink { if let b = $0?.receivedBytes { seenBytes.append(b) } }
        s.download(variant: .flash, flashQuant: .q2q4)
        // Wait until the bar has climbed past the first reported step.
        await until { (s.download?.receivedBytes ?? 0) >= 50 * 1024 * 1024 }
        token.cancel()
        XCTAssertGreaterThanOrEqual(
            s.download?.receivedBytes ?? 0, 50 * 1024 * 1024,
            "expected the callback to drive growing receivedBytes, saw: \(seenBytes)")
        XCTAssertTrue(seenBytes.contains { $0 > 0 }, "the @download publisher must observe growth, saw: \(seenBytes)")
        s.cancelDownload()
    }

    /// SupervisorService-level bitmap resume: seed a `<file>.part.dl` sidecar (a couple of chunks
    /// marked complete) plus a sparse preallocated `.part`, then `resumeInFlightDownloadIfAny` must
    /// re-enter `.downloading` off the bitmap (not the legacy `.incomplete` path), and the bitmap's
    /// durable bytes are reflected via `resumableBytes`/`downloadedBytes`.
    func testResumeFromBitmapSidecar() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let g = dir.appendingPathComponent("gguf")
        try FileManager.default.createDirectory(at: g, withIntermediateDirectories: true)
        try stubDs4(dir)
        let filename = Quant.proImatrix.ggufFilename
        let part = g.appendingPathComponent(filename + ".part")
        // Small chunks so a handful represents a meaningful total; mark chunks 0 and 1 complete. The
        // helper closes the bitmap's sidecar handle on return, leaving the `.part.dl` on disk for
        // resume to read back (it never calls bitmap.delete()).
        let chunkSize: Int64 = 16 * 1024 * 1024
        let total = chunkSize * 8
        try seedResumablePartial(part: part, total: total, chunkSize: chunkSize, completeChunks: 2)

        // The sidecar must report two chunks' worth of durable bytes.
        XCTAssertEqual(resumableBytes(ggufDir: g, filename: filename), 2 * chunkSize)
        XCTAssertEqual(downloadedBytes(ggufDir: g, filename: filename), 2 * chunkSize)

        let s = SupervisorService(ds4Dir: dir, runner: RealProcessRunner(), fetchFile: Self.pending)
        s.resumeInFlightDownloadIfAny(variant: .pro, flashQuant: .q2q4)
        XCTAssertEqual(s.state, .downloading, "a bitmap with completed chunks must trigger resume")
        XCTAssertEqual(s.download?.file, filename)
        XCTAssertTrue(s.downloadProcessLive)
        s.cancelDownload()
    }

    /// Cancel is a DELETE: a deliberate stop discards the partial. Seed a real sparse `<file>.part`
    /// plus its `<file>.part.dl` bitmap sidecar (a couple chunks complete — the canonical seeding from
    /// `testResumeFromBitmapSidecar`), enter `.downloading`, then `cancelDownload()` must remove BOTH
    /// the `.part` and the `.part.dl`. A mutation dropping either `removeItem` (or deleting the wrong
    /// path) leaves a file behind and fails here.
    func testCancelDownloadDeletesPartAndSidecar() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let g = dir.appendingPathComponent("gguf")
        try FileManager.default.createDirectory(at: g, withIntermediateDirectories: true)
        try stubDs4(dir)
        let q = Quant.for(.flash, flashQuant: .q2q4)
        let filename = q.ggufFilename
        let part = g.appendingPathComponent(filename + ".part")
        let sidecar = g.appendingPathComponent(filename + ".part.dl")
        // Seed a sparse preallocated `.part` truncated to the full size, plus a bitmap with two chunks
        // marked complete — exactly as the real downloader leaves a resumable partial. Seeding via the
        // helper guarantees the bitmap's `.part.dl` FileHandle is CLOSED before cancel runs, so cancel's
        // `removeItem(.part.dl)` deletes the directory entry deterministically (an open fd to that inode
        // would otherwise let `fileExists(.part.dl)` linger true depending on ARC/optimizer ordering).
        let chunkSize: Int64 = 16 * 1024 * 1024
        let total = chunkSize * 8
        try seedResumablePartial(part: part, total: total, chunkSize: chunkSize, completeChunks: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path), "seeded .part must exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path), "seeded .part.dl must exist")

        let s = SupervisorService(ds4Dir: dir, runner: RealProcessRunner(), fetchFile: Self.pending)
        s.download(variant: .flash, flashQuant: .q2q4)
        XCTAssertEqual(s.state, .downloading)
        XCTAssertEqual(s.download?.file, filename)

        s.cancelDownload()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: part.path), "cancel must delete the .part")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sidecar.path), "cancel must delete the .part.dl sidecar")
        XCTAssertEqual(s.state, .idle)
        XCTAssertNil(s.download)
        XCTAssertFalse(s.downloadProcessLive)
    }

    /// Failure is a KEEP: a download that fails (vs. is cancelled) leaves the partial on disk so a
    /// retry/relaunch resumes from the bitmap. The fake writes a real sparse `<file>.part` + bitmap
    /// sidecar (one chunk complete), reports progress once, then throws — driving `failDownload`, which
    /// (unlike `cancelDownload`) does NOT delete the partial. Locks the KEEP-on-failure vs.
    /// DELETE-on-cancel asymmetry.
    func testFailDownloadKeepsPartAndSidecar() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let g = dir.appendingPathComponent("gguf")
        try FileManager.default.createDirectory(at: g, withIntermediateDirectories: true)
        try stubDs4(dir)
        let q = Quant.for(.flash, flashQuant: .q2q4)
        let filename = q.ggufFilename
        let chunkSize: Int64 = 16 * 1024 * 1024
        let total = chunkSize * 8
        // Fake fetch: create the real partial in the destDir (2nd positional arg), report one progress
        // tick, then throw the retries-exhausted failure. No network.
        let failing: SupervisorService.FetchFile = { _, destDir, _, _, onProgress in
            let part = destDir.appendingPathComponent(filename + ".part")
            FileManager.default.createFile(atPath: part.path, contents: nil)
            let bitmap = try ChunkBitmap.loadOrCreate(
                partURL: part, total: total, chunkSize: chunkSize, seedContiguousBytes: 0)
            try bitmap.markComplete(0)
            let sizer = try FileHandle(forWritingTo: part)
            try sizer.truncate(atOffset: UInt64(total))
            try sizer.close()
            onProgress(chunkSize, total)
            throw HFDownloader.Failure.incompleteAfterRetries
        }
        let s = SupervisorService(ds4Dir: dir, runner: RealProcessRunner(), fetchFile: failing)
        s.download(variant: .flash, flashQuant: .q2q4)
        await until { if case .error = s.state { return true } else { return false } }

        let part = g.appendingPathComponent(filename + ".part")
        let sidecar = g.appendingPathComponent(filename + ".part.dl")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: part.path), "failure must KEEP the .part")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sidecar.path), "failure must KEEP the .part.dl sidecar")
        XCTAssertGreaterThan(
            resumableBytes(ggufDir: g, filename: filename), 0, "the kept bitmap must record durable bytes")
        guard case .error = s.state else { return XCTFail("expected .error, got \(s.state)") }
    }

    /// Retry must resume from the bitmap, not wipe durable progress. Seed a real `<file>.part` +
    /// `<file>.part.dl` with two chunks complete, enter `.downloading`, then `retryDownload`: the
    /// partial and its sidecar must SURVIVE and `resumableBytes` must be unchanged (>= 2 chunks),
    /// proving retry restarts the fetch off the existing bitmap rather than deleting it (which is the
    /// cancel path's job, not retry's).
    func testRetryPreservesBitmapSidecar() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let g = dir.appendingPathComponent("gguf")
        try FileManager.default.createDirectory(at: g, withIntermediateDirectories: true)
        try stubDs4(dir)
        let q = Quant.for(.flash, flashQuant: .q2q4)
        let filename = q.ggufFilename
        let part = g.appendingPathComponent(filename + ".part")
        let sidecar = g.appendingPathComponent(filename + ".part.dl")
        let chunkSize: Int64 = 16 * 1024 * 1024
        let total = chunkSize * 8
        try seedResumablePartial(part: part, total: total, chunkSize: chunkSize, completeChunks: 2)
        XCTAssertEqual(resumableBytes(ggufDir: g, filename: filename), 2 * chunkSize)

        let s = SupervisorService(ds4Dir: dir, runner: RealProcessRunner(), fetchFile: Self.pending)
        s.download(variant: .flash, flashQuant: .q2q4)
        XCTAssertEqual(s.state, .downloading)

        s.retryDownload(variant: .flash, flashQuant: .q2q4)
        XCTAssertEqual(s.state, .downloading, "retry re-enters .downloading")
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path), "retry must preserve the .part")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sidecar.path), "retry must preserve the .part.dl sidecar")
        XCTAssertEqual(
            resumableBytes(ggufDir: g, filename: filename), 2 * chunkSize,
            "retry must not wipe durable bitmap progress")
        s.cancelDownload()
    }

    func testCleanupRemovesUnselectedFlashQuantsKeepingPro() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let g = dir.appendingPathComponent("gguf")
        try FileManager.default.createDirectory(at: g, withIntermediateDirectories: true)
        // Seed all three Flash quants + the Pro file on disk.
        for q in FlashQuant.allCases {
            try Data(count: 4).write(to: g.appendingPathComponent(q.quant.ggufFilename))
        }
        try Data(count: 4).write(to: g.appendingPathComponent(Quant.proImatrix.ggufFilename))
        let s = SupervisorService(ds4Dir: dir, runner: RealProcessRunner())
        XCTAssertTrue(FlashQuant.allCases.allSatisfy { s.isFlashQuantDownloaded($0) })
        let before = s.ggufStoreVersion

        let removed = s.cleanupUnusedFlashQuants(keep: .q2q4)

        XCTAssertEqual(Set(removed), [FlashQuant.q2.quant.ggufFilename, FlashQuant.q4.quant.ggufFilename])
        XCTAssertTrue(s.isFlashQuantDownloaded(.q2q4))  // selected kept
        XCTAssertFalse(s.isFlashQuantDownloaded(.q2))  // removed
        XCTAssertFalse(s.isFlashQuantDownloaded(.q4))  // removed
        XCTAssertTrue(  // V4 Pro always kept
            FileManager.default.fileExists(
                atPath: g.appendingPathComponent(Quant.proImatrix.ggufFilename).path))
        XCTAssertEqual(s.ggufStoreVersion, before + 1)
    }
}
