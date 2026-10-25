import XCTest
@testable import DS4Control

final class GGUFShardDownloadTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func artifact(_ fixture: GGUFShardFixture) -> GGUFShardDownload.Artifact {
        GGUFShardDownload.Artifact(
            repo: "test/model", downloadRevision: "fixed-revision", ggufFilename: "model.gguf",
            ggufBytes: Int64(fixture.expected.count), sha256: fixture.plan.expectedSHA256,
            downloadParts: fixture.parts)
    }

    func testIncrementalFlowDeletesPriorStageBeforeDownloadingNextAndReverifiesPublishedOutput() async throws {
        let fixture = try GGUFShardFixture.make()
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = ShardFixtureSource(fixture: fixture)
        let reports = ShardReports()
        try await GGUFShardDownload.run(
            artifact: artifact(fixture), directory: dir, token: nil, highPerformance: false,
            fetchFile: source.fetchFile, fetchPrefix: source.fetchPrefix,
            onProgress: reports.record)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("model.gguf")), fixture.expected)
        let fetched = await source.fetched
        XCTAssertEqual(fetched, [0, 1])
        XCTAssertTrue(
            fixture.parts.allSatisfy {
                !FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.filename).path)
            })
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.gguf.verified").path))
        XCTAssertTrue(reports.phases.contains(.assembling))
        XCTAssertTrue(reports.phases.contains(.verifying))
        XCTAssertEqual(reports.lastBytes, fixture.parts.reduce(0) { $0 + $1.bytes })
        // The marker is supervisor-owned. A second invocation needs neither headers nor shards.
        try await GGUFShardDownload.run(
            artifact: artifact(fixture), directory: dir, token: nil, highPerformance: false,
            fetchFile: { _, _, _, _, _, _, _ in XCTFail("published file fetched again") },
            fetchPrefix: { _, _, _, _, _, _ in
                XCTFail("published file fetched headers"); return Data()
            },
            onProgress: { _, _, _ in })
    }

    func testNetworkFailureResumesAfterCommittedDeletedShard() async throws {
        let fixture = try GGUFShardFixture.make()
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = ShardFixtureSource(fixture: fixture, failOnceAt: 1)
        do {
            try await GGUFShardDownload.run(
                artifact: artifact(fixture), directory: dir, token: nil, highPerformance: false,
                fetchFile: source.fetchFile, fetchPrefix: source.fetchPrefix, onProgress: { _, _, _ in })
            XCTFail("expected interrupted second download")
        } catch HFDownloader.Failure.http(503) {}
        let target = dir.appendingPathComponent("model.gguf")
        XCTAssertEqual(
            GGUFShardAssembler.completedShardCount(target: target, expectedSHA256: fixture.plan.expectedSHA256), 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(fixture.parts[0].filename).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let leftover = dir.appendingPathComponent(fixture.parts[0].filename + ".part")
        try Data([1, 2, 3]).write(to: leftover)
        try await GGUFShardDownload.run(
            artifact: artifact(fixture), directory: dir, token: nil, highPerformance: false,
            fetchFile: source.fetchFile, fetchPrefix: source.fetchPrefix, onProgress: { _, _, _ in })
        let fetched = await source.fetched
        XCTAssertEqual(fetched, [0, 1, 1], "committed shard zero must not be fetched again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertEqual(try Data(contentsOf: target), fixture.expected)
    }

    func testSpaceFailureHappensBeforeDownloadingAnyShard() async throws {
        let fixture = try GGUFShardFixture.make()
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = ShardFixtureSource(fixture: fixture)
        do {
            try await GGUFShardDownload.run(
                artifact: artifact(fixture), directory: dir, token: nil, highPerformance: false,
                fetchFile: source.fetchFile, fetchPrefix: source.fetchPrefix,
                availableSpace: { _ in 0 }, onProgress: { _, _, _ in })
            XCTFail("expected insufficient capacity")
        } catch GGUFJoiner.Failure.notEnoughDiskSpace {}
        let fetched = await source.fetched
        XCTAssertEqual(fetched, [])
    }

    func testUnexpectedDirectoriesAtArtifactPathsAreNeverDeleted() async throws {
        let fixture = try GGUFShardFixture.make()
        for filename in ["model.gguf", fixture.parts[0].filename, fixture.parts[0].filename + ".part"] {
            let dir = try directory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let unexpected = dir.appendingPathComponent(filename)
            try FileManager.default.createDirectory(at: unexpected, withIntermediateDirectories: true)
            let sentinel = unexpected.appendingPathComponent("keep.txt")
            try Data("keep".utf8).write(to: sentinel)
            let source = ShardFixtureSource(fixture: fixture)
            do {
                try await GGUFShardDownload.run(
                    artifact: artifact(fixture), directory: dir, token: nil, highPerformance: false,
                    fetchFile: source.fetchFile, fetchPrefix: source.fetchPrefix, onProgress: { _, _, _ in })
                XCTFail("unexpected directory accepted")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
            let fetched = await source.fetched
            XCTAssertTrue(fetched.isEmpty)
        }
    }

    func testCorruptStageIsDiscardedWithoutAdvancingJournal() async throws {
        let fixture = try GGUFShardFixture.make()
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = ShardFixtureSource(fixture: fixture, corruptOnceAt: 0)
        do {
            try await GGUFShardDownload.run(
                artifact: artifact(fixture), directory: dir, token: nil, highPerformance: false,
                fetchFile: source.fetchFile, fetchPrefix: source.fetchPrefix, onProgress: { _, _, _ in })
            XCTFail("expected failed shard digest")
        } catch GGUFJoiner.Failure.checksumMismatch {}
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(fixture.parts[0].filename).path))
        XCTAssertEqual(
            GGUFShardAssembler.completedShardCount(
                target: dir.appendingPathComponent("model.gguf"), expectedSHA256: fixture.plan.expectedSHA256), 0)
        try await GGUFShardDownload.run(
            artifact: artifact(fixture), directory: dir, token: nil, highPerformance: false,
            fetchFile: source.fetchFile, fetchPrefix: source.fetchPrefix, onProgress: { _, _, _ in })
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("model.gguf")), fixture.expected)
    }
}

private actor ShardFixtureSource {
    let fixture: GGUFShardFixture
    private var failOnceAt: Int?
    private var corruptOnceAt: Int?
    private(set) var fetched: [Int] = []
    init(fixture: GGUFShardFixture, failOnceAt: Int? = nil, corruptOnceAt: Int? = nil) {
        self.fixture = fixture
        self.failOnceAt = failOnceAt
        self.corruptOnceAt = corruptOnceAt
    }
    nonisolated var fetchFile: SupervisorService.FetchFile {
        { repo, revision, file, dir, _, _, progress in
            XCTAssertEqual(repo, "test/model")
            XCTAssertEqual(revision, "fixed-revision")
            try await self.fetch(file: file, directory: dir, progress: progress)
        }
    }
    nonisolated var fetchPrefix: SupervisorService.FetchPrefix {
        { _, revision, file, count, bytes, _ in
            XCTAssertEqual(revision, "fixed-revision")
            return try await self.prefix(file: file, count: count, bytes: bytes)
        }
    }
    func prefix(file: String, count: Int, bytes: Int64) throws -> Data {
        let index = try XCTUnwrap(fixture.parts.firstIndex { $0.filename == file })
        XCTAssertEqual(bytes, fixture.parts[index].bytes)
        return Data(fixture.shards[index].prefix(count))
    }
    func fetch(file: String, directory: URL, progress: @Sendable (Int64, Int64) -> Void) throws {
        let index = try XCTUnwrap(fixture.parts.firstIndex { $0.filename == file })
        fetched.append(index)
        for part in fixture.parts.prefix(index) {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: directory.appendingPathComponent(part.filename).path),
                "earlier stage must be deleted before the next download starts")
        }
        if failOnceAt == index { failOnceAt = nil; throw HFDownloader.Failure.http(503) }
        var bytes = fixture.shards[index]
        if corruptOnceAt == index { corruptOnceAt = nil; bytes[bytes.count - 1] ^= 1 }
        try bytes.write(to: directory.appendingPathComponent(file))
        progress(Int64(bytes.count), Int64(bytes.count))
    }
}

private final class ShardReports: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(DownloadProgress.Phase, Int64)] = []
    func record(_ phase: DownloadProgress.Phase, _ file: String, _ bytes: Int64) {
        lock.withLock { values.append((phase, bytes)) }
    }
    var phases: [DownloadProgress.Phase] { lock.withLock { values.map(\.0) } }
    var lastBytes: Int64? { lock.withLock { values.last?.1 } }
}
