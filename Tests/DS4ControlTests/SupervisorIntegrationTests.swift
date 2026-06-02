import XCTest
import Combine
@testable import DS4Control

@MainActor
final class SupervisorIntegrationTests: XCTestCase {
    func testResumeAttachesToInFlightPartial() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let dl = dir.appendingPathComponent("gguf/.cache/huggingface/download")
        try FileManager.default.createDirectory(at: dl, withIntermediateDirectories: true)
        try Data(count: 5_000_000).write(to: dl.appendingPathComponent("h.incomplete"))
        let s = SupervisorService(ds4Dir: dir, runner: RealProcessRunner())
        s.resumeInFlightDownloadIfAny(variant: .pro, flashQuant: .q2q4)
        XCTAssertEqual(s.state, .downloading)
        XCTAssertEqual(s.download?.receivedBytes, 5_000_000)
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
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = repoRoot.appendingPathComponent("Tests/Fixtures")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("gguf/.cache/huggingface/download"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("fake-ds4-server.sh"), to: dir.appendingPathComponent("ds4-server"))
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("fake-download_cr.sh"),
            to: dir.appendingPathComponent("download_model.sh"))
        for f in ["ds4-server", "download_model.sh"] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent(f).path)
        }
        // Simulate a stuck partial, then retry from idle.
        try Data(count: 1024).write(
            to: dir.appendingPathComponent("gguf/.cache/huggingface/download/h.incomplete"))
        let s = SupervisorService(ds4Dir: dir, runner: RealProcessRunner())
        s.retryDownload(variant: .pro, flashQuant: .q2q4)
        XCTAssertEqual(s.state, .downloading)
        XCTAssertNotNil(s.download)
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

    func testDownloadProgressAgainstFakeScript() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = repoRoot.appendingPathComponent("Tests/Fixtures")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("fake-ds4-server.sh"), to: dir.appendingPathComponent("ds4-server"))
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("fake-download_model.sh"),
            to: dir.appendingPathComponent("download_model.sh"))
        for f in ["ds4-server", "download_model.sh"] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent(f).path)
        }
        let s = SupervisorService(ds4Dir: dir, runner: RealProcessRunner())
        let done = expectation(description: "download idle")
        let token = s.$state.sink { if $0 == .idle, s.download?.pct == 100 { done.fulfill() } }
        s.download(variant: .flash, flashQuant: .q2q4)
        wait(for: [done], timeout: 10)
        token.cancel()
    }

    func testDownloadStreamsIntermediateProgress() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = repoRoot.appendingPathComponent("Tests/Fixtures")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("fake-ds4-server.sh"), to: dir.appendingPathComponent("ds4-server"))
        // Use the CR-style script as download_model.sh
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("fake-download_cr.sh"),
            to: dir.appendingPathComponent("download_model.sh"))
        for f in ["ds4-server", "download_model.sh"] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent(f).path)
        }
        let s = SupervisorService(ds4Dir: dir, runner: RealProcessRunner())
        var seenPcts: [Double] = []
        let token = s.$download.sink { if let p = $0?.pct { seenPcts.append(p) } }
        let done = expectation(description: "download idle")
        let stateToken = s.$state.sink { if $0 == .idle, s.download?.pct == 100 { done.fulfill() } }
        s.download(variant: .flash, flashQuant: .q2q4)
        wait(for: [done], timeout: 10)
        token.cancel(); stateToken.cancel()
        // Must have observed at least one intermediate (>0, <100) value — proves live streaming, not a 0→100 jump.
        XCTAssertTrue(seenPcts.contains { $0 > 0 && $0 < 100 }, "expected intermediate progress, saw: \(seenPcts)")
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
