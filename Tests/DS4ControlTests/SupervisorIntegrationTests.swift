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
        s.resumeInFlightDownloadIfAny(variant: .pro)
        XCTAssertEqual(s.state, .downloading)
        XCTAssertEqual(s.download?.receivedBytes, 5_000_000)
    }

    func testResumeNoOpWhenNoPartial() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("gguf"), withIntermediateDirectories: true)
        let s = SupervisorService(ds4Dir: dir, runner: RealProcessRunner())
        s.resumeInFlightDownloadIfAny(variant: .pro)
        XCTAssertEqual(s.state, .idle)
    }

    func testResumeNoOpWhenComplete() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let g = dir.appendingPathComponent("gguf")
        try FileManager.default.createDirectory(at: g, withIntermediateDirectories: true)
        try Data(count: 10).write(to: g.appendingPathComponent(Quant.proImatrix.ggufFilename))
        let s = SupervisorService(ds4Dir: dir, runner: RealProcessRunner())
        s.resumeInFlightDownloadIfAny(variant: .pro)
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
        s.retryDownload(variant: .pro)
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

    func testResumeAttachesToRunningServer() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fakeServer = repoRoot.appendingPathComponent("Tests/Fixtures/fake-ds4-server.sh")
        let port = 8251
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/bin/sh")
        server.arguments = [fakeServer.path, "--port", "\(port)"]
        server.standardOutput = Pipe()
        server.standardError = Pipe()
        try server.run()
        defer { server.terminate() }
        Thread.sleep(forTimeInterval: 2)  // let the fake server bind + start serving

        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = SupervisorService(ds4Dir: dir, runner: RealProcessRunner())
        let ready = expectation(description: "attached ready")
        let token = s.$state.sink { if $0 == .ready { ready.fulfill() } }
        s.resumeRunningServerIfAny(port: port)
        wait(for: [ready], timeout: 8)
        token.cancel()
        XCTAssertNotNil(s.activeModel)
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
        // The supervisor resolves the gguf via Quant.for(.flash, ramGiB: systemRamGiB());
        // create the file the host's RAM actually selects so the fixture matches on any machine.
        let hostQuant = Quant.for(.flash, ramGiB: systemRamGiB())
        let gg = dir.appendingPathComponent("gguf").appendingPathComponent(hostQuant.ggufFilename)
        FileManager.default.createFile(atPath: gg.path, contents: Data("gguf".utf8))

        let s = SupervisorService(ds4Dir: dir, runner: RealProcessRunner())
        s.start(variant: .flash, ctx: 250_000, port: 8137, power: nil)
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
        s.download(variant: .flash)
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
        s.download(variant: .flash)
        wait(for: [done], timeout: 10)
        token.cancel(); stateToken.cancel()
        // Must have observed at least one intermediate (>0, <100) value — proves live streaming, not a 0→100 jump.
        XCTAssertTrue(seenPcts.contains { $0 > 0 && $0 < 100 }, "expected intermediate progress, saw: \(seenPcts)")
    }
}
