import XCTest
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

private func createValidSparseGGUF(at url: URL, quant: Quant) throws {
    FileManager.default.createFile(atPath: url.path, contents: Data("GGUF".utf8))
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(ModelFileValidator.minimumBytes(for: quant)))
    try handle.close()
}

@MainActor
final class SupervisorStateMachineTests: XCTestCase {
    fileprivate func makeSupervisor(_ runner: FakeRunner) throws -> SupervisorService {
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
        try createValidSparseGGUF(at: gg, quant: hostQuant)
        return SupervisorService(ds4Dir: dir, runner: runner)
    }

    func testStartReachesReady() throws {
        let r = FakeRunner(); let s = try makeSupervisor(r)
        s.start(variant: .flash, flashQuant: .q2q4, ctx: 250_000, port: 8000, power: nil)
        XCTAssertEqual(s.state, .starting)
        r.emit("ds4-server: listening on http://127.0.0.1:8000")
        XCTAssertEqual(s.state, .ready)
        XCTAssertTrue(r.lastArgs.contains("--metal"))
        XCTAssertTrue(r.lastArgs.contains("250000"))
        XCTAssertFalse(r.lastArgs.contains("--kv-disk-dir"))  // omitted when no dir passed
    }
    func testStartAddsKvDiskArgsWhenDirProvided() throws {
        let r = FakeRunner(); let s = try makeSupervisor(r)
        let kv = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        s.start(variant: .flash, flashQuant: .q2q4, ctx: 250_000, port: 8000, power: nil, kvDiskDir: kv)
        XCTAssertTrue(r.lastArgs.contains("--kv-disk-dir"))
        XCTAssertTrue(r.lastArgs.contains(kv.path))
        XCTAssertTrue(r.lastArgs.contains("--kv-disk-space-mb"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kv.path))  // created
    }
    func testCrashIsError() throws {
        let r = FakeRunner(); let s = try makeSupervisor(r)
        s.start(variant: .flash, flashQuant: .q2q4, ctx: 250_000, port: 8000, power: nil)
        r.emit("some log line"); r.crash(1)
        if case .error(.crashed) = s.state {} else { XCTFail("expected crashed, got \(s.state)") }
    }
    func testStop() throws {
        let r = FakeRunner(); let s = try makeSupervisor(r)
        s.start(variant: .flash, flashQuant: .q2q4, ctx: 250_000, port: 8000, power: nil)
        r.emit("ds4-server: listening on http://127.0.0.1:8000")
        s.stop()
        XCTAssertEqual(s.state, .idle)
    }
    func testRestartRelaunchesWithNewSettings() throws {
        let r = FakeRunner(); let s = try makeSupervisor(r)
        s.start(variant: .flash, flashQuant: .q2q4, ctx: 250_000, port: 8000, power: nil)
        r.emit("ds4-server: listening on http://127.0.0.1:8000")
        XCTAssertEqual(s.state, .ready)

        s.restart(variant: .flash, flashQuant: .q2q4, ctx: 393_216, port: 8000, power: nil)
        // FakeRunner.terminate fires exit(0) inline, so the relaunch happens immediately.
        XCTAssertEqual(s.state, .starting)
        XCTAssertTrue(r.lastArgs.contains("393216"))  // new ctx applied to the relaunch
        XCTAssertEqual(s.ctx, 393_216)

        r.emit("ds4-server: listening on http://127.0.0.1:8000")
        XCTAssertEqual(s.state, .ready)
    }
    func testRestartIgnoredWhenNotRunning() throws {
        let r = FakeRunner(); let s = try makeSupervisor(r)
        s.restart(variant: .flash, flashQuant: .q2q4, ctx: 393_216, port: 8000, power: nil)
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
        s.start(variant: .flash, flashQuant: .q2q4, ctx: 250_000, port: 8000, power: nil)
        if case .error(.modelMissing) = s.state {} else { XCTFail("expected modelMissing, got \(s.state)") }
    }
    func testIsDownloadedRejectsCorruptExistingModelFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let ggufDir = dir.appendingPathComponent("gguf")
        try FileManager.default.createDirectory(at: ggufDir, withIntermediateDirectories: true)
        for f in ["ds4-server", "download_model.sh"] {
            let u = dir.appendingPathComponent(f)
            FileManager.default.createFile(atPath: u.path, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        }
        let model = ggufDir.appendingPathComponent(Quant.q2q4Imatrix.ggufFilename)
        try Data("BAD!".utf8).write(to: model)
        let s = SupervisorService(ds4Dir: dir, runner: FakeRunner())

        XCTAssertFalse(s.isDownloaded(.flash, flashQuant: .q2q4))
    }
    func testStartRejectsCorruptExistingModelFileWithoutLaunching() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let ggufDir = dir.appendingPathComponent("gguf")
        try FileManager.default.createDirectory(at: ggufDir, withIntermediateDirectories: true)
        for f in ["ds4-server", "download_model.sh"] {
            let u = dir.appendingPathComponent(f)
            FileManager.default.createFile(atPath: u.path, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        }
        let model = ggufDir.appendingPathComponent(Quant.q2q4Imatrix.ggufFilename)
        try Data("GGUF".utf8).write(to: model)
        let runner = FakeRunner()
        let s = SupervisorService(ds4Dir: dir, runner: runner)

        s.start(variant: .flash, flashQuant: .q2q4, ctx: 250_000, port: 8000, power: nil)

        if case .error = s.state {} else { XCTFail("expected invalid model error, got \(s.state)") }
        XCTAssertFalse(runner.isRunning)
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
