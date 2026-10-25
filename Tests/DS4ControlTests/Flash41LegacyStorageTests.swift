import XCTest
@testable import DS4Control

private final class LegacyStorageRunner: ProcessRunner {
    var isRunning = false
    func launch(
        executable: URL, args: [String], cwd: URL, env: [String: String],
        removingEnvironmentKeys: Set<String>,
        onStderrLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws { isRunning = true }
    func terminate(graceSeconds: Double) { isRunning = false }
}

final class Flash41LegacyStorageTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var gguf: URL { root.appendingPathComponent("gguf", isDirectory: true) }
    private var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }
    private var oldQ2: String { "DeepSeek-V4.1-Flash-Q2.gguf" }
    private var oldQ4: String { "DeepSeek-V4.1-Flash-Q4.gguf" }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("flash41-cleanup-\(UUID().uuidString)")
        try fm.createDirectory(at: gguf, withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func write(_ name: String, in base: URL? = nil) throws -> URL {
        let url = (base ?? gguf).appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old model artifact".utf8).write(to: url)
        return url
    }

    @MainActor private func supervisor(_ runner: LegacyStorageRunner = LegacyStorageRunner()) -> SupervisorService {
        SupervisorService(
            ds4Dir: root, runner: runner, serverProbe: { _ in nil },
            ggufBaseURL: gguf, cacheBaseURL: cache, listeningPIDLookup: { _ in .none })
    }

    @MainActor private func app() -> AppState {
        AppState(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!, ramGiB: 512)
    }

    func testCandidatesIncludeExactOldArtifactsAndKeep1017AndUnrelatedHFData() throws {
        let oldNames = [
            oldQ2, oldQ2 + ".verified", oldQ2 + ".part", oldQ2 + ".part.dl",
            oldQ2 + ".part.lock", oldQ4, oldQ4 + ".assembling", oldQ4 + ".assembling.lock",
            oldQ4 + ".part1", oldQ4 + ".part1.verified", oldQ4 + ".part1.part.dl",
            oldQ4 + ".part2", oldQ4 + ".part2.part", oldQ4 + ".part2.part.dl.lock",
        ]
        var oldURLs = try oldNames.map { try write($0) }
        let hf = gguf.appendingPathComponent(".cache/huggingface/download")
        oldURLs += try [
            oldQ2 + ".metadata", oldQ2 + ".lock", oldQ4 + ".part1." + String(repeating: "a", count: 64) + ".incomplete",
        ]
        .map { try write($0, in: hf) }
        let oldCache = cache.appendingPathComponent("kv-flash-41")
        _ = try write("session.kv", in: oldCache)
        oldURLs.append(oldCache)
        let kept = try [
            Quant.q41Q2.ggufFilename, Quant.q41MXFP4.ggufFilename,
            Quant.q41MXFP4.downloadParts[0].filename, "other-model.gguf", oldQ2 + ".backup",
        ].map { try write($0) }
        let keptHF = try ["unrelated.incomplete", "another.gguf.metadata", oldQ2 + ".not-an-etag.incomplete"]
            .map { try write($0, in: hf) }
        let newCache = try write(
            "session.kv", in: cache.appendingPathComponent(QuantSelection.flash41(.q2).kvCacheDirectoryName))

        let candidates = Flash41LegacyStorage.candidates(ggufDirectory: gguf, cacheDirectory: cache)
        XCTAssertEqual(Set(candidates.map(\.path)), Set(oldURLs.map(\.path)))
        XCTAssertGreaterThan(Flash41LegacyStorage.totalBytes(for: candidates), 0)
        try Flash41LegacyStorage.remove(candidates: candidates, ggufDirectory: gguf, cacheDirectory: cache)

        XCTAssertTrue(oldURLs.allSatisfy { !fm.fileExists(atPath: $0.path) })
        XCTAssertTrue((kept + keptHF + [newCache]).allSatisfy { fm.fileExists(atPath: $0.path) })
        XCTAssertTrue(Flash41LegacyStorage.candidates(ggufDirectory: gguf, cacheDirectory: cache).isEmpty)
    }

    @MainActor func testCancelMakesNoChangesAndKeepsPromptAvailable() throws {
        let old = try write(oldQ2)
        let state = app()
        let result = Flash41LegacyCleanupPrompt.confirm(supervisor: supervisor(), app: state) { paths, bytes in
            XCTAssertEqual(paths, [old])
            XCTAssertGreaterThan(bytes, 0)
            return false
        }
        XCTAssertNil(result)
        XCTAssertTrue(fm.fileExists(atPath: old.path))
        XCTAssertFalse(state.legacyFlash41StoragePromptDismissed)
    }

    @MainActor func testOnlyTheConfirmedSnapshotIsDeleted() throws {
        let old = try write(oldQ2)
        let later = gguf.appendingPathComponent(oldQ4)
        let state = app()
        let result = Flash41LegacyCleanupPrompt.confirm(supervisor: supervisor(), app: state) { paths, _ in
            XCTAssertEqual(paths, [old])
            _ = try? self.write(self.oldQ4)
            return true
        }
        XCTAssertNil(result)
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: later.path))
        XCTAssertFalse(state.legacyFlash41StoragePromptDismissed)
    }

    @MainActor func testProcessGateIsRecheckedAfterConfirmation() throws {
        let old = try write(oldQ2)
        let runner = LegacyStorageRunner()
        let service = supervisor(runner)
        let state = app()
        let result = Flash41LegacyCleanupPrompt.confirm(supervisor: service, app: state) { _, _ in
            runner.isRunning = true
            return true
        }
        XCTAssertNotNil(result)
        XCTAssertTrue(fm.fileExists(atPath: old.path))
        XCTAssertFalse(state.legacyFlash41StoragePromptDismissed)
    }

    func testFailureReportsTheRemainingPathAndAllowsRetry() throws {
        let succeeds = try write(oldQ2)
        let fails = try write(oldQ4)
        do {
            try Flash41LegacyStorage.remove(
                candidates: [succeeds, fails], ggufDirectory: gguf, cacheDirectory: cache
            ) { url in
                if url == fails { throw CocoaError(.fileWriteNoPermission) }
                try self.fm.removeItem(at: url)
            }
            XCTFail("Expected a partial cleanup failure")
        } catch let error as Flash41LegacyStorage.CleanupError {
            XCTAssertEqual(error.removed, [succeeds])
            XCTAssertEqual(error.failures.count, 1)
            XCTAssertTrue(error.localizedDescription.contains(fails.path))
        }
        let remaining = Flash41LegacyStorage.candidates(ggufDirectory: gguf, cacheDirectory: cache)
        XCTAssertEqual(remaining, [fails])
        try Flash41LegacyStorage.remove(candidates: remaining, ggufDirectory: gguf, cacheDirectory: cache)
        XCTAssertFalse(fm.fileExists(atPath: fails.path))
    }

    func testSymlinksCannotEscapeTheCleanupRoots() throws {
        let outside = root.appendingPathComponent("outside")
        let valuable = try write("valuable.gguf", in: outside)
        let link = gguf.appendingPathComponent(oldQ2)
        try fm.createSymbolicLink(at: link, withDestinationURL: valuable)
        XCTAssertThrowsError(
            try Flash41LegacyStorage.remove(candidates: [link], ggufDirectory: gguf, cacheDirectory: cache))
        XCTAssertEqual(Flash41LegacyStorage.totalBytes(for: [link]), 0)
        XCTAssertTrue(fm.fileExists(atPath: valuable.path))

        let outsideLock = try write(oldQ4 + ".lock", in: outside.appendingPathComponent("huggingface/download"))
        try fm.createSymbolicLink(at: gguf.appendingPathComponent(".cache"), withDestinationURL: outside)
        let traversal = gguf.appendingPathComponent(".cache/huggingface/download/" + oldQ4 + ".lock")
        XCTAssertFalse(Flash41LegacyStorage.candidates(ggufDirectory: gguf, cacheDirectory: cache).contains(traversal))
        XCTAssertThrowsError(
            try Flash41LegacyStorage.remove(candidates: [traversal], ggufDirectory: gguf, cacheDirectory: cache))
        XCTAssertTrue(fm.fileExists(atPath: outsideLock.path))
    }

    func testArbitraryConfirmedPathsAreRejected() throws {
        let current = try write(Quant.q41Q2.ggufFilename)
        let unrelated = try write(
            "unrelated.incomplete", in: gguf.appendingPathComponent(".cache/huggingface/download"))
        XCTAssertThrowsError(
            try Flash41LegacyStorage.remove(
                candidates: [current, unrelated], ggufDirectory: gguf, cacheDirectory: cache))
        XCTAssertTrue(fm.fileExists(atPath: current.path))
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path))
    }

    func testOldCacheCleanupDoesNotFollowNestedSymlinks() throws {
        let outside = root.appendingPathComponent("outside")
        let valuable = try write("session.kv", in: outside)
        let oldCache = cache.appendingPathComponent("kv-flash-41")
        try fm.createDirectory(at: oldCache, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: oldCache.appendingPathComponent("linked-session"), withDestinationURL: outside)
        try Flash41LegacyStorage.remove(candidates: [oldCache], ggufDirectory: gguf, cacheDirectory: cache)
        XCTAssertFalse(fm.fileExists(atPath: oldCache.path))
        XCTAssertTrue(fm.fileExists(atPath: valuable.path))
    }
}
