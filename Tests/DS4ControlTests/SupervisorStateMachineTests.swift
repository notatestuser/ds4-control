import XCTest
@testable import DS4Control

private final class FakeRunner: ProcessRunner {
    var isRunning = false
    var lastArgs: [String] = []
    private var stderr: ((String) -> Void)?
    private var exit: ((Int32) -> Void)?
    func launch(executable: URL, args: [String], cwd: URL,
                onStderrLine: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) throws {
        lastArgs = args; isRunning = true; stderr = onStderrLine; exit = onExit
    }
    func terminate(graceSeconds: Double) { isRunning = false; exit?(0) }
    func emit(_ line: String) { stderr?(line) }
    func crash(_ code: Int32) { isRunning = false; exit?(code) }
}

@MainActor
final class SupervisorStateMachineTests: XCTestCase {
    fileprivate func makeSupervisor(_ runner: FakeRunner) throws -> SupervisorService {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("gguf"), withIntermediateDirectories: true)
        for f in ["ds4-server", "download_model.sh"] {
            let u = dir.appendingPathComponent(f); FileManager.default.createFile(atPath: u.path, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        }
        // The supervisor resolves the gguf via Quant.for(.flash, ramGiB: systemRamGiB());
        // create the file the host's RAM actually selects so the fixture matches on any machine.
        let hostQuant = Quant.for(.flash, ramGiB: systemRamGiB())
        let gg = dir.appendingPathComponent("gguf").appendingPathComponent(hostQuant.ggufFilename)
        FileManager.default.createFile(atPath: gg.path, contents: Data("gguf".utf8))
        return SupervisorService(ds4Dir: dir, runner: runner)
    }

    func testStartReachesReady() throws {
        let r = FakeRunner(); let s = try makeSupervisor(r)
        s.start(variant: .flash, ctx: 250_000, port: 8000, power: nil)
        XCTAssertEqual(s.state, .starting)
        r.emit("ds4-server: listening on http://127.0.0.1:8000")
        XCTAssertEqual(s.state, .ready)
        XCTAssertTrue(r.lastArgs.contains("--metal"))
        XCTAssertTrue(r.lastArgs.contains("250000"))
    }
    func testCrashIsError() throws {
        let r = FakeRunner(); let s = try makeSupervisor(r)
        s.start(variant: .flash, ctx: 250_000, port: 8000, power: nil)
        r.emit("some log line"); r.crash(1)
        if case .error(.crashed) = s.state {} else { XCTFail("expected crashed, got \(s.state)") }
    }
    func testStop() throws {
        let r = FakeRunner(); let s = try makeSupervisor(r)
        s.start(variant: .flash, ctx: 250_000, port: 8000, power: nil)
        r.emit("ds4-server: listening on http://127.0.0.1:8000")
        s.stop()
        XCTAssertEqual(s.state, .idle)
    }
    func testMissingModel() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in ["ds4-server", "download_model.sh"] {
            let u = dir.appendingPathComponent(f); FileManager.default.createFile(atPath: u.path, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        }
        let s = SupervisorService(ds4Dir: dir, runner: FakeRunner())
        s.start(variant: .flash, ctx: 250_000, port: 8000, power: nil)
        if case .error(.modelMissing) = s.state {} else { XCTFail("expected modelMissing, got \(s.state)") }
    }
}
