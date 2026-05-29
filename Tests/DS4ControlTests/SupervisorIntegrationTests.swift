import XCTest
import Combine
@testable import DS4Control

@MainActor
final class SupervisorIntegrationTests: XCTestCase {
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
