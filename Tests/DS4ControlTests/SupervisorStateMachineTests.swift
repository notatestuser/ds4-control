import XCTest
import Combine
@testable import DS4Control

private final class FakeRunner: ProcessRunner {
    var isRunning = false
    var lastArgs: [String] = []
    var lastEnv: [String: String] = [:]
    private var stderr: (@Sendable (String) -> Void)?
    private var exit: (@Sendable (Int32) -> Void)?
    func launch(
        executable: URL, args: [String], cwd: URL, env: [String: String],
        onStderrLine: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        lastArgs = args; lastEnv = env; isRunning = true; stderr = onStderrLine; exit = onExit
    }
    func terminate(graceSeconds: Double) { isRunning = false; exit?(0) }
    func emit(_ line: String) { stderr?(line) }
    func crash(_ code: Int32) { isRunning = false; exit?(code) }
}

@MainActor
final class SupervisorStateMachineTests: XCTestCase {
    // `probe` defaults to a hermetic "no server" — an unexpected exit now triggers an
    // adoption probe, and the real default would hit a live ds4-server on the dev machine.
    fileprivate func makeSupervisor(
        _ runner: FakeRunner, probe: @escaping (Int) async -> Data? = { _ in nil }
    ) throws -> SupervisorService {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("gguf"), withIntermediateDirectories: true)
        for f in ["ds4-server", "download_model.sh"] {
            let u = dir.appendingPathComponent(f);
            FileManager.default.createFile(atPath: u.path, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        }
        // The supervisor resolves the gguf via Quant.for(.flash, flashQuant:); create the
        // file for the quant the tests start with (.q2q4) so the fixture matches.
        let hostQuant = Quant.for(.flash, flashQuant: .q2q4)
        let gg = dir.appendingPathComponent("gguf").appendingPathComponent(hostQuant.ggufFilename)
        FileManager.default.createFile(atPath: gg.path, contents: Data("gguf".utf8))
        return SupervisorService(ds4Dir: dir, runner: runner, serverProbe: probe)
    }

    func testStartReachesReady() throws {
        let r = FakeRunner(); let s = try makeSupervisor(r)
        s.start(variant: .flash, flashQuant: .q2q4, ctx: 250_000, host: "0.0.0.0", port: 8000, power: nil)
        XCTAssertEqual(s.state, .starting)
        r.emit("ds4-server: listening on http://127.0.0.1:8000")
        XCTAssertEqual(s.state, .ready)
        XCTAssertTrue(r.lastArgs.contains("--metal"))
        XCTAssertTrue(r.lastArgs.contains("250000"))
        XCTAssertEqual(r.lastArgs[r.lastArgs.firstIndex(of: "--host")! + 1], "0.0.0.0")
        XCTAssertFalse(r.lastArgs.contains("--kv-disk-dir"))  // omitted when no dir passed
    }
    func testStartNormalizesHostBeforeLaunch() throws {
        let r = FakeRunner(); let s = try makeSupervisor(r)
        s.start(variant: .flash, flashQuant: .q2q4, ctx: 250_000, host: " \n0.0.0.0\t ", port: 8000, power: nil)
        XCTAssertEqual(r.lastArgs[r.lastArgs.firstIndex(of: "--host")! + 1], "0.0.0.0")

        let r2 = FakeRunner(); let s2 = try makeSupervisor(r2)
        s2.start(variant: .flash, flashQuant: .q2q4, ctx: 250_000, host: " \n\t ", port: 8000, power: nil)
        XCTAssertEqual(r2.lastArgs[r2.lastArgs.firstIndex(of: "--host")! + 1], "127.0.0.1")
    }

    func testStartAddsKvDiskArgsWhenDirProvided() throws {
        let r = FakeRunner(); let s = try makeSupervisor(r)
        let kv = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        s.start(
            variant: .flash, flashQuant: .q2q4, ctx: 250_000, host: "127.0.0.1", port: 8000,
            power: nil, kvDiskDir: kv)
        XCTAssertTrue(r.lastArgs.contains("--kv-disk-dir"))
        XCTAssertTrue(r.lastArgs.contains(kv.path))
        XCTAssertTrue(r.lastArgs.contains("--kv-disk-space-mb"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kv.path))  // created
    }
    func testStartAddsBatchedSessionArgOnlyWhenSessionsAboveOne() throws {
        let r = FakeRunner(); let s = try makeSupervisor(r)
        s.start(
            variant: .flash, flashQuant: .q2q4, ctx: 250_000, host: "127.0.0.1", port: 8000,
            power: nil, sessions: 3)
        XCTAssertEqual(r.lastArgs[r.lastArgs.firstIndex(of: "--batched-session")! + 1], "3")

        // Default (1) omits the flag: ds4 treats even `--batched-session 1` as batched mode.
        let r2 = FakeRunner(); let s2 = try makeSupervisor(r2)
        s2.start(variant: .flash, flashQuant: .q2q4, ctx: 250_000, host: "127.0.0.1", port: 8000, power: nil)
        XCTAssertFalse(r2.lastArgs.contains("--batched-session"))
    }
    func testCrashIsError() throws {
        let r = FakeRunner(); let s = try makeSupervisor(r)
        s.start(variant: .flash, flashQuant: .q2q4, ctx: 250_000, host: "127.0.0.1", port: 8000, power: nil)
        r.emit("some log line"); r.crash(1)
        if case .error(.crashed) = s.state {} else { XCTFail("expected crashed, got \(s.state)") }
    }
    func testCrashAdoptsHealthyServerOnPort() throws {
        // The spawned server died (e.g. bind conflict with an orphaned ds4-server that owns
        // the port). If that port-holder answers the probe, adopt it as .ready instead of
        // dead-ending in .error with a Retry button that can only fail the same way again.
        let body = Data(
            #"{"object":"list","data":[{"id":"deepseek-v4-flash","name":"DeepSeek V4 Flash","context_length":1000000}]}"#
                .utf8)
        let r = FakeRunner(); let s = try makeSupervisor(r, probe: { _ in body })
        s.start(variant: .flash, flashQuant: .q2q4, ctx: 250_000, host: "127.0.0.1", port: 8000, power: nil)
        r.crash(1)
        let ready = expectation(description: "adopted as ready")
        let token = s.$state.sink { if $0 == .ready { ready.fulfill() } }
        wait(for: [ready], timeout: 5)
        token.cancel()
        XCTAssertEqual(s.activeModel, "DeepSeek V4 Flash")
        XCTAssertEqual(s.ctx, 1_000_000)  // adopted server's context, not the start-time 250_000
    }
    func testStop() throws {
        let r = FakeRunner(); let s = try makeSupervisor(r)
        s.start(variant: .flash, flashQuant: .q2q4, ctx: 250_000, host: "127.0.0.1", port: 8000, power: nil)
        r.emit("ds4-server: listening on http://127.0.0.1:8000")
        s.stop()
        XCTAssertEqual(s.state, .idle)
    }
    func testRestartRelaunchesWithNewSettings() throws {
        let r = FakeRunner(); let s = try makeSupervisor(r)
        s.start(variant: .flash, flashQuant: .q2q4, ctx: 250_000, host: "127.0.0.1", port: 8000, power: nil)
        r.emit("ds4-server: listening on http://127.0.0.1:8000")
        XCTAssertEqual(s.state, .ready)

        s.restart(variant: .flash, flashQuant: .q2q4, ctx: 393_216, host: "0.0.0.0", port: 8000, power: nil)
        // FakeRunner.terminate fires exit(0) inline, so the relaunch happens immediately.
        XCTAssertEqual(s.state, .starting)
        XCTAssertTrue(r.lastArgs.contains("393216"))  // new ctx applied to the relaunch
        XCTAssertEqual(r.lastArgs[r.lastArgs.firstIndex(of: "--host")! + 1], "0.0.0.0")
        XCTAssertEqual(s.ctx, 393_216)

        r.emit("ds4-server: listening on http://127.0.0.1:8000")
        XCTAssertEqual(s.state, .ready)
    }
    func testRestartIgnoredWhenNotRunning() throws {
        let r = FakeRunner(); let s = try makeSupervisor(r)
        s.restart(variant: .flash, flashQuant: .q2q4, ctx: 393_216, host: "127.0.0.1", port: 8000, power: nil)
        XCTAssertEqual(s.state, .idle)  // no-op; nothing to restart
    }
    func testMissingModel() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in ["ds4-server", "download_model.sh"] {
            let u = dir.appendingPathComponent(f);
            FileManager.default.createFile(atPath: u.path, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        }
        let s = SupervisorService(ds4Dir: dir, runner: FakeRunner())
        s.start(variant: .flash, flashQuant: .q2q4, ctx: 250_000, host: "127.0.0.1", port: 8000, power: nil)
        if case .error(.modelMissing) = s.state {} else { XCTFail("expected modelMissing, got \(s.state)") }
    }
    func testDownloadUsesSelectedQuantFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("gguf"), withIntermediateDirectories: true)
        for f in ["ds4-server", "download_model.sh"] {
            let u = dir.appendingPathComponent(f)
            FileManager.default.createFile(atPath: u.path, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        }
        let s = SupervisorService(
            ds4Dir: dir, runner: FakeRunner(),
            fetchFile: { _, _, _, _, _ in try await Task.sleep(nanoseconds: 600_000_000_000) })
        s.download(variant: .flash, flashQuant: .q2q4)
        XCTAssertEqual(s.state, .downloading)
        XCTAssertEqual(s.download?.file, Quant.q2q4Imatrix.ggufFilename)  // selected quant's gguf
        s.cancelDownload()
    }
}
