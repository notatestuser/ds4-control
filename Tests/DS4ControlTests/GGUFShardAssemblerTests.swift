import CryptoKit
import XCTest

@testable import DS4Control

/// Shared, independent GGUF serializer for assembly and download orchestration tests.
/// The expected whole file is serialized directly, rather than derived from a merge plan.
struct GGUFShardFixture {
    struct Tensor {
        let name: String
        let shape: [UInt64]
        let kind: UInt32
        let payload: Data

        init(name: String, shape: [UInt64]? = nil, kind: UInt32 = 24, payload: Data) {
            self.name = name
            self.shape = shape ?? [UInt64(payload.count)]
            self.kind = kind
            self.payload = payload
        }
    }

    let shards: [Data]
    let parts: [QuantPart]
    let headers: [GGUFShardAssembler.Header]
    let expected: Data
    let plan: GGUFShardAssembler.Plan

    static func make(
        payloads: [Data] = [Data([1, 2, 3]), Data([4, 5])],
        expectedSHA256: String? = nil
    ) throws -> GGUFShardFixture {
        let tensors = payloads.enumerated().map { [Tensor(name: "tensor.\($0.offset)", payload: $0.element)] }
        return try make(tensors: tensors, expectedSHA256: expectedSHA256)
    }

    static func make(tensors: [[Tensor]], expectedSHA256: String? = nil) throws -> GGUFShardFixture {
        let total = tensors.reduce(0) { $0 + $1.count }
        let shards = tensors.enumerated().map {
            makeShard(index: $0.offset, count: tensors.count, totalTensors: total, tensors: $0.element)
        }
        let parts = shards.enumerated().map {
            QuantPart(
                filename: "fixture-\($0.offset + 1).gguf", bytes: Int64($0.element.count), sha256: sha256($0.element))
        }
        let headers = try zip(shards, parts).map { try GGUFShardAssembler.parseHeader($0.0, fileBytes: $0.1.bytes) }
        let expected = serialize(
            metadata: baseMetadata(alignment: 16_384), tensors: tensors.flatMap { $0 }, alignment: 16_384)
        let plan = try GGUFShardAssembler.makePlan(
            headers: headers, parts: parts,
            expectedBytes: Int64(expected.count),
            expectedSHA256: expectedSHA256 ?? sha256(expected))
        return GGUFShardFixture(shards: shards, parts: parts, headers: headers, expected: expected, plan: plan)
    }

    static func makeShard(
        index: Int, count: Int, totalTensors: Int, tensors: [Tensor],
        extraMetadata: [Data] = []
    ) -> Data {
        var metadata = index == 0 ? baseMetadata(alignment: 32) : []
        metadata += [
            u16Metadata("split.no", UInt16(index)), u16Metadata("split.count", UInt16(count)),
            i32Metadata("split.tensors.count", Int32(totalTensors)),
        ]
        metadata += extraMetadata
        return serialize(metadata: metadata, tensors: tensors, alignment: 32)
    }

    static func baseMetadata(alignment: UInt32) -> [Data] {
        var array = encodedString("custom.array")
        array.appendLittle(UInt32(9))
        array.appendLittle(UInt32(8))
        array.appendLittle(UInt64(2))
        array.append(encodedString("a"))
        array.append(encodedString("λ"))
        return [
            stringMetadata("general.architecture", "deepseek41"),
            u32Metadata("general.alignment", alignment), stringMetadata("custom.note", "preserve λ"), array,
        ]
    }

    static func serialize(metadata: [Data], tensors: [Tensor], alignment: Int) -> Data {
        var data = Data("GGUF".utf8)
        data.appendLittle(UInt32(3))
        data.appendLittle(UInt64(tensors.count))
        data.appendLittle(UInt64(metadata.count))
        for raw in metadata { data.append(raw) }
        var offset: UInt64 = 0
        for tensor in tensors {
            data.append(encodedString(tensor.name))
            data.appendLittle(UInt32(tensor.shape.count))
            for dimension in tensor.shape { data.appendLittle(dimension) }
            data.appendLittle(tensor.kind)
            data.appendLittle(offset)
            offset += UInt64(align(tensor.payload.count, to: alignment))
        }
        data.append(Data(repeating: 0, count: align(data.count, to: alignment) - data.count))
        for tensor in tensors {
            data.append(tensor.payload)
            data.append(Data(repeating: 0xA5, count: align(tensor.payload.count, to: alignment) - tensor.payload.count))
        }
        // Original GGUF padding is zero; shard padding deliberately is not, proving it
        // is reconstructed rather than copied along with the actual tensor bytes.
        if alignment == 16_384 {
            var position = align(directoryBytes(metadata: metadata, tensors: tensors), to: alignment)
            for tensor in tensors {
                let paddingStart = position + tensor.payload.count
                let end = position + align(tensor.payload.count, to: alignment)
                data.replaceSubrange(paddingStart..<end, with: Data(repeating: 0, count: end - paddingStart))
                position = end
            }
        }
        return data
    }

    private static func directoryBytes(metadata: [Data], tensors: [Tensor]) -> Int {
        24 + metadata.reduce(0) { $0 + $1.count }
            + tensors.reduce(0) {
                $0 + 8 + $1.name.utf8.count + 4 + $1.shape.count * 8 + 4 + 8
            }
    }
    static func encodedString(_ value: String) -> Data {
        var data = Data()
        data.appendLittle(UInt64(value.utf8.count))
        data.append(Data(value.utf8))
        return data
    }
    static func stringMetadata(_ key: String, _ value: String) -> Data {
        var data = encodedString(key)
        data.appendLittle(UInt32(8))
        data.append(encodedString(value))
        return data
    }
    static func u16Metadata(_ key: String, _ value: UInt16) -> Data {
        var data = encodedString(key)
        data.appendLittle(UInt32(2))
        data.appendLittle(value)
        return data
    }
    static func u32Metadata(_ key: String, _ value: UInt32) -> Data {
        var data = encodedString(key)
        data.appendLittle(UInt32(4))
        data.appendLittle(value)
        return data
    }
    static func i32Metadata(_ key: String, _ value: Int32) -> Data {
        var data = encodedString(key)
        data.appendLittle(UInt32(5))
        data.appendLittle(value)
        return data
    }
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func align(_ bytes: Int, to alignment: Int) -> Int { (bytes + alignment - 1) / alignment * alignment }
}

final class GGUFShardAssemblerTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func stage(_ fixture: GGUFShardFixture, index: Int, directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(fixture.parts[index].filename)
        try fixture.shards[index].write(to: url)
        return url
    }

    private func appendAll(
        _ fixture: GGUFShardFixture, target: URL,
        deleteStagedShard: Bool = true
    ) throws -> GGUFShardAssembler.Progress {
        var progress = try GGUFShardAssembler.recover(plan: fixture.plan, target: target)
        for index in progress.completedShards..<fixture.shards.count {
            let shard = try stage(fixture, index: index, directory: target.deletingLastPathComponent())
            progress = try GGUFShardAssembler.append(
                shard: shard, index: index, plan: fixture.plan,
                target: target, progress: progress,
                availableBytes: Int64.max,
                deleteStagedShard: deleteStagedShard)
        }
        return progress
    }

    func testReconstructsReferenceGGUFWithAllSupportedTensorTypes() throws {
        let fixture = try GGUFShardFixture.make(tensors: [
            [
                GGUFShardFixture.Tensor(
                    name: "mxfp4", shape: [32], kind: 39, payload: Data(repeating: 0x39, count: 17)),
                GGUFShardFixture.Tensor(name: "q8", shape: [32], kind: 8, payload: Data(repeating: 8, count: 34)),
            ],
            [
                GGUFShardFixture.Tensor(name: "f32", shape: [2], kind: 0, payload: Data(repeating: 0, count: 8)),
                GGUFShardFixture.Tensor(name: "f16", shape: [2], kind: 1, payload: Data(repeating: 1, count: 4)),
                GGUFShardFixture.Tensor(name: "i8", payload: Data([2, 3, 4])),
            ],
        ])
        let directory = try temporaryDirectory()
        let target = directory.appendingPathComponent("model.gguf")
        var progress = try GGUFShardAssembler.recover(plan: fixture.plan, target: target)
        XCTAssertEqual(fixture.plan.header, fixture.expected.prefix(fixture.plan.header.count))
        for index in fixture.shards.indices {
            let input = try stage(fixture, index: index, directory: directory)
            progress = try GGUFShardAssembler.append(
                shard: input, index: index, plan: fixture.plan,
                target: target, progress: progress, availableBytes: Int64.max)
            XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: GGUFShardAssembler.checkpointURL(for: target).path))
            XCTAssertEqual(
                GGUFShardAssembler.completedShardCount(target: target, expectedSHA256: fixture.plan.expectedSHA256),
                index + 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
        try GGUFShardAssembler.finalize(plan: fixture.plan, target: target, progress: progress)
        XCTAssertEqual(try Data(contentsOf: target), fixture.expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: GGUFShardAssembler.assemblyURL(for: target).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: GGUFShardAssembler.checkpointURL(for: target).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path + ".verified"))
    }

    func testRangePrefixReportsTypedIncompleteHeaderAndAcceptsExactDirectory() throws {
        let fixture = try GGUFShardFixture.make()
        let bytes = fixture.shards[0]
        XCTAssertThrowsError(try GGUFShardAssembler.parseHeader(bytes.prefix(24), fileBytes: Int64(bytes.count))) {
            guard case GGUFShardAssembler.Failure.incompleteHeader(let required) = $0 else { return XCTFail("\($0)") }
            XCTAssertGreaterThan(required, 24)
            XCTAssertLessThanOrEqual(required, GGUFShardAssembler.maximumHeaderBytes)
        }
        let header = try GGUFShardAssembler.parseHeader(
            bytes.prefix(fixture.headers[0].raw.count), fileBytes: Int64(bytes.count))
        XCTAssertEqual(header.sha256, fixture.headers[0].sha256)
        XCTAssertLessThan(header.raw.count, bytes.count)
    }

    func testRejectsTruncatedOversizedAndOverflowingHeaders() throws {
        let fixture = try GGUFShardFixture.make()
        var tooMany = Data("GGUF".utf8)
        tooMany.appendLittle(UInt32(3))
        tooMany.appendLittle(UInt64(100_001))
        tooMany.appendLittle(UInt64(0))
        var hugeString = Data("GGUF".utf8)
        hugeString.appendLittle(UInt32(3))
        hugeString.appendLittle(UInt64(0))
        hugeString.appendLittle(UInt64(1))
        hugeString.appendLittle(UInt64.max)
        let overflow = GGUFShardFixture.makeShard(
            index: 0, count: 1, totalTensors: 1,
            tensors: [
                .init(name: "overflow", shape: [UInt64.max, 2], payload: Data([1]))
            ])
        for (bytes, declared) in [
            (Data([1, 2, 3]), Int64(3)), (tooMany, Int64(tooMany.count)),
            (hugeString, Int64.max), (overflow, Int64(overflow.count)),
            (fixture.shards[0], Int64(fixture.shards[0].count - 1)),
        ] {
            XCTAssertThrowsError(try GGUFShardAssembler.parseHeader(bytes, fileBytes: declared)) {
                guard case GGUFShardAssembler.Failure.invalidHeader = $0 else { return XCTFail("\($0)") }
            }
        }
    }

    func testRejectsMissingOutOfOrderDuplicateAndUnexpectedMetadata() throws {
        let fixture = try GGUFShardFixture.make()
        XCTAssertThrowsError(
            try GGUFShardAssembler.makePlan(
                headers: [fixture.headers[0]], parts: [fixture.parts[0]],
                expectedBytes: fixture.plan.expectedBytes,
                expectedSHA256: fixture.plan.expectedSHA256))
        XCTAssertThrowsError(
            try GGUFShardAssembler.makePlan(
                headers: fixture.headers.reversed(), parts: fixture.parts.reversed(),
                expectedBytes: fixture.plan.expectedBytes,
                expectedSHA256: fixture.plan.expectedSHA256))
        XCTAssertThrowsError(
            try GGUFShardFixture.make(tensors: [
                [.init(name: "duplicate", payload: Data([1]))],
                [.init(name: "duplicate", payload: Data([2]))],
            ]))
        let unexpected = GGUFShardFixture.makeShard(
            index: 1, count: 2, totalTensors: 2,
            tensors: [.init(name: "tensor.1", payload: Data([4, 5]))],
            extraMetadata: [GGUFShardFixture.stringMetadata("unexpected", "value")])
        let unexpectedHeader = try GGUFShardAssembler.parseHeader(unexpected, fileBytes: Int64(unexpected.count))
        let unexpectedPart = QuantPart(
            filename: "unexpected.gguf", bytes: Int64(unexpected.count),
            sha256: GGUFShardFixture.sha256(unexpected))
        XCTAssertThrowsError(
            try GGUFShardAssembler.makePlan(
                headers: [fixture.headers[0], unexpectedHeader],
                parts: [fixture.parts[0], unexpectedPart],
                expectedBytes: fixture.plan.expectedBytes,
                expectedSHA256: fixture.plan.expectedSHA256))
        let duplicateKey = GGUFShardFixture.makeShard(
            index: 0, count: 1, totalTensors: 1,
            tensors: [.init(name: "a", payload: Data([1]))],
            extraMetadata: [GGUFShardFixture.u16Metadata("split.no", 0)])
        XCTAssertThrowsError(try GGUFShardAssembler.parseHeader(duplicateKey, fileBytes: Int64(duplicateKey.count)))
    }

    func testInterruptedAppendTruncatesOnlyUncommittedTail() throws {
        let fixture = try GGUFShardFixture.make()
        let directory = try temporaryDirectory()
        let target = directory.appendingPathComponent("model.gguf")
        var progress = try GGUFShardAssembler.recover(plan: fixture.plan, target: target)
        let first = try stage(fixture, index: 0, directory: directory)
        progress = try GGUFShardAssembler.append(
            shard: first, index: 0, plan: fixture.plan,
            target: target, progress: progress, availableBytes: Int64.max)
        let output = try FileHandle(forWritingTo: GGUFShardAssembler.assemblyURL(for: target))
        try output.seekToEnd()
        try output.write(contentsOf: Data(repeating: 0xFF, count: 100))
        try output.close()
        let recovered = try GGUFShardAssembler.recover(plan: fixture.plan, target: target)
        XCTAssertEqual(recovered.completedShards, 1)
        XCTAssertEqual(recovered.completedBytes, progress.completedBytes)
        XCTAssertEqual(
            try Data(contentsOf: GGUFShardAssembler.assemblyURL(for: target)),
            fixture.expected.prefix(Int(progress.completedBytes)))
        let second = try stage(fixture, index: 1, directory: directory)
        let completed = try GGUFShardAssembler.append(
            shard: second, index: 1, plan: fixture.plan,
            target: target, progress: recovered, availableBytes: Int64.max)
        try GGUFShardAssembler.finalize(plan: fixture.plan, target: target, progress: completed)
        XCTAssertEqual(try Data(contentsOf: target), fixture.expected)
    }

    func testRecoveryFindsEarliestCorruptShardAndDiscardsItsTail() throws {
        let fixture = try GGUFShardFixture.make(payloads: [Data([1]), Data([2]), Data([3])])
        let directory = try temporaryDirectory()
        let target = directory.appendingPathComponent("model.gguf")
        _ = try appendAll(fixture, target: target, deleteStagedShard: false)
        let output = try FileHandle(forUpdating: GGUFShardAssembler.assemblyURL(for: target))
        try output.seek(toOffset: UInt64(fixture.plan.shards[1].outputOffset))
        try output.write(contentsOf: Data([0xEE]))
        try output.close()
        let recovered = try GGUFShardAssembler.recover(plan: fixture.plan, target: target)
        XCTAssertEqual(recovered.completedShards, 1)
        XCTAssertEqual(recovered.completedBytes, fixture.plan.shards[0].endOffset)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(fixture.parts[0].filename).path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(fixture.parts[1].filename).path))
        XCTAssertEqual(
            try Data(contentsOf: GGUFShardAssembler.assemblyURL(for: target)),
            fixture.expected.prefix(Int(recovered.completedBytes)))
        let completed = try appendAll(fixture, target: target)
        try GGUFShardAssembler.finalize(plan: fixture.plan, target: target, progress: completed)
        XCTAssertEqual(try Data(contentsOf: target), fixture.expected)
    }

    func testRecoveryAfterCheckpointBeforeInputDeletion() throws {
        let fixture = try GGUFShardFixture.make()
        let directory = try temporaryDirectory()
        let target = directory.appendingPathComponent("model.gguf")
        let initial = try GGUFShardAssembler.recover(plan: fixture.plan, target: target)
        let first = try stage(fixture, index: 0, directory: directory)
        _ = try GGUFShardAssembler.append(
            shard: first, index: 0, plan: fixture.plan, target: target,
            progress: initial, availableBytes: Int64.max, deleteStagedShard: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        let recovered = try GGUFShardAssembler.recover(plan: fixture.plan, target: target)
        XCTAssertEqual(recovered.completedShards, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }

    func testCorruptHeaderWithMatchingJournalRestartsAtFirstShard() throws {
        let fixture = try GGUFShardFixture.make()
        let directory = try temporaryDirectory()
        let target = directory.appendingPathComponent("model.gguf")
        _ = try appendAll(fixture, target: target, deleteStagedShard: false)
        let output = try FileHandle(forUpdating: GGUFShardAssembler.assemblyURL(for: target))
        try output.seek(toOffset: 0)
        try output.write(contentsOf: Data([0]))
        try output.close()
        let recovered = try GGUFShardAssembler.recover(plan: fixture.plan, target: target)
        XCTAssertEqual(recovered.completedShards, 0)
        XCTAssertEqual(try Data(contentsOf: GGUFShardAssembler.assemblyURL(for: target)), fixture.plan.header)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(fixture.parts[0].filename).path))
    }

    func testTruncatedCommittedOutputKeepsEarlierValidShards() throws {
        let fixture = try GGUFShardFixture.make()
        let directory = try temporaryDirectory()
        let target = directory.appendingPathComponent("model.gguf")
        _ = try appendAll(fixture, target: target)
        let output = try FileHandle(forWritingTo: GGUFShardAssembler.assemblyURL(for: target))
        try output.truncate(atOffset: UInt64(fixture.plan.shards[0].endOffset + 1))
        try output.close()
        let recovered = try GGUFShardAssembler.recover(plan: fixture.plan, target: target)
        XCTAssertEqual(recovered.completedShards, 1)
        XCTAssertEqual(recovered.completedBytes, fixture.plan.shards[0].endOffset)
        XCTAssertEqual(
            try Data(contentsOf: GGUFShardAssembler.assemblyURL(for: target)),
            fixture.expected.prefix(Int(recovered.completedBytes)))
    }

    func testStaleProgressCannotRollBackCommittedShard() throws {
        let fixture = try GGUFShardFixture.make()
        let directory = try temporaryDirectory()
        let target = directory.appendingPathComponent("model.gguf")
        let initial = try GGUFShardAssembler.recover(plan: fixture.plan, target: target)
        let input = try stage(fixture, index: 0, directory: directory)
        let committed = try GGUFShardAssembler.append(
            shard: input, index: 0, plan: fixture.plan,
            target: target, progress: initial, availableBytes: Int64.max,
            deleteStagedShard: false)
        XCTAssertThrowsError(
            try GGUFShardAssembler.append(
                shard: input, index: 0, plan: fixture.plan,
                target: target, progress: initial, availableBytes: Int64.max))
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
        XCTAssertEqual(
            try Data(contentsOf: GGUFShardAssembler.assemblyURL(for: target)).count, Int(committed.completedBytes))
        XCTAssertEqual(
            GGUFShardAssembler.completedShardCount(target: target, expectedSHA256: fixture.plan.expectedSHA256), 1)
    }

    func testInputDeletionFailureIsSurfacedAfterDurableCheckpoint() throws {
        let fixture = try GGUFShardFixture.make()
        let directory = try temporaryDirectory()
        let target = directory.appendingPathComponent("model.gguf")
        let initial = try GGUFShardAssembler.recover(plan: fixture.plan, target: target)
        let inputDirectory = directory.appendingPathComponent("read-only-stage")
        try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: false)
        let input = try stage(fixture, index: 0, directory: inputDirectory)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: inputDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inputDirectory.path) }
        XCTAssertThrowsError(
            try GGUFShardAssembler.append(
                shard: input, index: 0, plan: fixture.plan,
                target: target, progress: initial, availableBytes: Int64.max))
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
        XCTAssertEqual(
            GGUFShardAssembler.completedShardCount(target: target, expectedSHA256: fixture.plan.expectedSHA256), 1)
        XCTAssertEqual(try GGUFShardAssembler.recover(plan: fixture.plan, target: target).completedShards, 1)
    }

    func testCheckpointFailureKeepsInputAndRecoveryRemovesUncommittedBytes() throws {
        let fixture = try GGUFShardFixture.make()
        let directory = try temporaryDirectory()
        let target = directory.appendingPathComponent("model.gguf")
        let initial = try GGUFShardAssembler.recover(plan: fixture.plan, target: target)
        let journal = GGUFShardAssembler.checkpointURL(for: target)
        let originalJournal = try Data(contentsOf: journal)
        let scratch = URL(fileURLWithPath: journal.path + ".tmp")
        // Leave the authoritative journal readable, then fail its replacement only
        // after the tensor bytes have been written and synchronized.
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        let input = try stage(fixture, index: 0, directory: directory)
        XCTAssertThrowsError(
            try GGUFShardAssembler.append(
                shard: input, index: 0, plan: fixture.plan,
                target: target, progress: initial, availableBytes: Int64.max))
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: journal), originalJournal)
        XCTAssertEqual(
            try Data(contentsOf: GGUFShardAssembler.assemblyURL(for: target)).count,
            Int(fixture.plan.shards[0].endOffset))
        try FileManager.default.removeItem(at: scratch)
        let recovered = try GGUFShardAssembler.recover(plan: fixture.plan, target: target)
        XCTAssertEqual(recovered.completedShards, 0)
        XCTAssertEqual(try Data(contentsOf: GGUFShardAssembler.assemblyURL(for: target)), fixture.plan.header)
    }

    func testHeaderMismatchAndIncorrectAppendOrderKeepInput() throws {
        let fixture = try GGUFShardFixture.make()
        let directory = try temporaryDirectory()
        let target = directory.appendingPathComponent("model.gguf")
        let initial = try GGUFShardAssembler.recover(plan: fixture.plan, target: target)
        let second = try stage(fixture, index: 1, directory: directory)
        XCTAssertThrowsError(
            try GGUFShardAssembler.append(
                shard: second, index: 1, plan: fixture.plan,
                target: target, progress: initial, availableBytes: Int64.max)
        ) {
            XCTAssertEqual($0 as? GGUFShardAssembler.Failure, .incorrectAppendOrder(expected: 0, actual: 1))
        }
        let first = try stage(fixture, index: 0, directory: directory)
        var changed = fixture.shards[0]
        changed[0] = 0
        try changed.write(to: first)
        XCTAssertThrowsError(
            try GGUFShardAssembler.append(
                shard: first, index: 0, plan: fixture.plan,
                target: target, progress: initial, availableBytes: Int64.max)
        ) {
            XCTAssertEqual($0 as? GGUFShardAssembler.Failure, .shardHeaderMismatch(first.lastPathComponent))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(try Data(contentsOf: GGUFShardAssembler.assemblyURL(for: target)), fixture.plan.header)
    }

    func testInsufficientSpaceDoesNotAppendOrDelete() throws {
        let fixture = try GGUFShardFixture.make()
        let directory = try temporaryDirectory()
        let target = directory.appendingPathComponent("model.gguf")
        let initial = try GGUFShardAssembler.recover(plan: fixture.plan, target: target)
        let first = try stage(fixture, index: 0, directory: directory)
        let required = fixture.plan.shards[0].outputBytes + GGUFShardAssembler.diskMargin
        XCTAssertThrowsError(
            try GGUFShardAssembler.append(
                shard: first, index: 0, plan: fixture.plan,
                target: target, progress: initial, availableBytes: required - 1)
        ) {
            XCTAssertEqual($0 as? GGUFShardAssembler.Failure, .notEnoughDiskSpace(requiredBytes: required))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(try Data(contentsOf: GGUFShardAssembler.assemblyURL(for: target)), fixture.plan.header)
        XCTAssertEqual(
            GGUFShardAssembler.completedShardCount(target: target, expectedSHA256: fixture.plan.expectedSHA256), 0)
    }

    func testPeakEstimatorAccountsForAlreadyAllocatedStageAndOutput() throws {
        let fixture = try GGUFShardFixture.make(payloads: [
            Data(repeating: 1, count: 33), Data(repeating: 2, count: 65),
        ])
        let first = fixture.plan.shards[0]
        let second = fixture.plan.shards[1]
        let header = Int64(fixture.plan.header.count)
        let stage0 = fixture.parts[0].bytes
        let stage1 = fixture.parts[1].bytes
        let peak = max(header + stage0 + first.outputBytes, header + first.outputBytes + stage1 + second.outputBytes)
        XCTAssertEqual(
            try GGUFShardAssembler.remainingPeakBytes(plan: fixture.plan, stagedBytes: [0, 0], marginBytes: 0), peak)
        XCTAssertEqual(
            try GGUFShardAssembler.remainingPeakBytes(plan: fixture.plan, stagedBytes: [10, 20], marginBytes: 0),
            peak - 30)
        let directory = try temporaryDirectory()
        let target = directory.appendingPathComponent("model.gguf")
        let progress = try GGUFShardAssembler.recover(plan: fixture.plan, target: target)
        XCTAssertEqual(
            try GGUFShardAssembler.remainingPeakBytes(
                plan: fixture.plan, progress: progress,
                stagedBytes: [0, 0], marginBytes: 0), peak - header)
        let input = try stage(fixture, index: 0, directory: directory)
        let appended = try GGUFShardAssembler.append(
            shard: input, index: 0, plan: fixture.plan,
            target: target, progress: progress, availableBytes: Int64.max)
        XCTAssertEqual(
            try GGUFShardAssembler.remainingPeakBytes(
                plan: fixture.plan, progress: appended,
                stagedBytes: [0, 0], marginBytes: 0), stage1 + second.outputBytes)
        XCTAssertEqual(
            try GGUFShardAssembler.remainingPeakBytes(
                plan: fixture.plan, progress: appended,
                stagedBytes: [0, stage1], marginBytes: 0), second.outputBytes)
        // A crash can leave an old .part beside an already committed shard. Its
        // allocation consumes current free space; no future append reclaims it.
        XCTAssertEqual(
            try GGUFShardAssembler.remainingPeakBytes(
                plan: fixture.plan, progress: appended,
                stagedBytes: [stage0, 0], marginBytes: 0), stage1 + second.outputBytes)
    }

    func testFinalChecksumMismatchNeverPublishesAndKeepsRecovery() throws {
        let fixture = try GGUFShardFixture.make(expectedSHA256: String(repeating: "0", count: 64))
        let directory = try temporaryDirectory()
        let target = directory.appendingPathComponent("model.gguf")
        let progress = try appendAll(fixture, target: target)
        XCTAssertThrowsError(try GGUFShardAssembler.finalize(plan: fixture.plan, target: target, progress: progress)) {
            XCTAssertEqual($0 as? GGUFShardAssembler.Failure, .finalChecksumMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path + ".verified"))
        XCTAssertEqual(try Data(contentsOf: GGUFShardAssembler.assemblyURL(for: target)), fixture.expected)
        XCTAssertEqual(
            try GGUFShardAssembler.recover(plan: fixture.plan, target: target).completedShards, fixture.shards.count)
    }

    func testDoesNotReplaceExistingTargetOrUnrelatedPartial() throws {
        let fixture = try GGUFShardFixture.make()
        let directory = try temporaryDirectory()
        let target = directory.appendingPathComponent("model.gguf")
        let progress = try appendAll(fixture, target: target)
        let unrelated = Data("unrelated".utf8)
        try unrelated.write(to: target)
        XCTAssertThrowsError(try GGUFShardAssembler.finalize(plan: fixture.plan, target: target, progress: progress))
        XCTAssertEqual(try Data(contentsOf: target), unrelated)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.removeItem(at: GGUFShardAssembler.checkpointURL(for: target))
        try unrelated.write(to: GGUFShardAssembler.assemblyURL(for: target))
        XCTAssertThrowsError(try GGUFShardAssembler.recover(plan: fixture.plan, target: target)) {
            XCTAssertEqual($0 as? GGUFShardAssembler.Failure, .assemblyIdentityMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: GGUFShardAssembler.assemblyURL(for: target)), unrelated)
    }

    func testLockExcludesOtherAssemblerAndCanBeReleased() throws {
        let target = try temporaryDirectory().appendingPathComponent("model.gguf")
        let first = try GGUFShardAssembler.acquireLock(target: target)
        XCTAssertThrowsError(try GGUFShardAssembler.acquireLock(target: target)) {
            XCTAssertEqual($0 as? GGUFShardAssembler.Failure, .assemblyLocked)
        }
        first.release()
        let second = try GGUFShardAssembler.acquireLock(target: target)
        second.release()
    }

    func testProgressProbeRejectsWrongIdentityAndMalformedCheckpoint() throws {
        let fixture = try GGUFShardFixture.make()
        let target = try temporaryDirectory().appendingPathComponent("model.gguf")
        _ = try appendAll(fixture, target: target)
        XCTAssertEqual(
            GGUFShardAssembler.completedShardCount(target: target, expectedSHA256: String(repeating: "0", count: 64)), 0
        )
        try Data("{}".utf8).write(to: GGUFShardAssembler.checkpointURL(for: target))
        XCTAssertEqual(
            GGUFShardAssembler.completedShardCount(target: target, expectedSHA256: fixture.plan.expectedSHA256), 0)
        XCTAssertThrowsError(try GGUFShardAssembler.recover(plan: fixture.plan, target: target))
    }

    func testRecoveryCleansInterruptedJournalScratchFile() throws {
        let fixture = try GGUFShardFixture.make()
        let target = try temporaryDirectory().appendingPathComponent("model.gguf")
        _ = try GGUFShardAssembler.recover(plan: fixture.plan, target: target)
        let scratch = URL(fileURLWithPath: GGUFShardAssembler.checkpointURL(for: target).path + ".tmp")
        try Data("interrupted journal".utf8).write(to: scratch)
        XCTAssertEqual(try GGUFShardAssembler.recover(plan: fixture.plan, target: target).completedShards, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
    }

    func testRefusesSymlinkAssemblyAndShardWithoutChangingTheirTargets() throws {
        let fixture = try GGUFShardFixture.make()
        let directory = try temporaryDirectory()
        let target = directory.appendingPathComponent("model.gguf")
        let outside = directory.appendingPathComponent("outside")
        try fixture.expected.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: GGUFShardAssembler.assemblyURL(for: target),
            withDestinationURL: outside)
        XCTAssertThrowsError(try GGUFShardAssembler.recover(plan: fixture.plan, target: target))
        XCTAssertEqual(try Data(contentsOf: outside), fixture.expected)
        try FileManager.default.removeItem(at: GGUFShardAssembler.assemblyURL(for: target))
        let progress = try GGUFShardAssembler.recover(plan: fixture.plan, target: target)
        let originalShard = directory.appendingPathComponent("original-shard")
        try fixture.shards[0].write(to: originalShard)
        let link = directory.appendingPathComponent(fixture.parts[0].filename)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: originalShard)
        XCTAssertThrowsError(
            try GGUFShardAssembler.append(
                shard: link, index: 0, plan: fixture.plan,
                target: target, progress: progress, availableBytes: Int64.max))
        XCTAssertEqual(try Data(contentsOf: originalShard), fixture.shards[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }

    func testRecoveryDoesNotRecursivelyDeleteDirectoryAtConsumedShardPath() throws {
        let fixture = try GGUFShardFixture.make()
        let directory = try temporaryDirectory()
        let target = directory.appendingPathComponent("model.gguf")
        let initial = try GGUFShardAssembler.recover(plan: fixture.plan, target: target)
        let input = try stage(fixture, index: 0, directory: directory)
        _ = try GGUFShardAssembler.append(
            shard: input, index: 0, plan: fixture.plan,
            target: target, progress: initial, availableBytes: Int64.max)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: false)
        let keep = input.appendingPathComponent("keep")
        try Data([42]).write(to: keep)
        XCTAssertThrowsError(try GGUFShardAssembler.recover(plan: fixture.plan, target: target))
        XCTAssertEqual(try Data(contentsOf: keep), Data([42]))
        XCTAssertEqual(
            GGUFShardAssembler.completedShardCount(target: target, expectedSHA256: fixture.plan.expectedSHA256), 1)
    }

    /// Set this path to ds4@a1012463383a09c6d11f8164218e0ee45e267acf's
    /// gguf-tools/merge_deepseek41_shards.py for an offline differential check.
    func testMatchesPinnedUpstreamMergerWhenReferenceIsProvided() throws {
        guard let script = ProcessInfo.processInfo.environment["DS4_GGUF_MERGE_REFERENCE"] else {
            throw XCTSkip(
                "Set DS4_GGUF_MERGE_REFERENCE to the pinned upstream merger for the optional differential test")
        }
        guard FileManager.default.fileExists(atPath: script) else { throw XCTSkip("Upstream merger is unavailable") }
        let fixture = try GGUFShardFixture.make(tensors: [
            [
                .init(name: "a", shape: [32, 2], kind: 39, payload: Data(repeating: 3, count: 34)),
                .init(name: "b", payload: Data([1, 2, 3])),
            ],
            [.init(name: "c", shape: [32], kind: 8, payload: Data(repeating: 4, count: 34))],
            [.init(name: "d", shape: [2], kind: 1, payload: Data([5, 6, 7, 8]))],
        ])
        let directory = try temporaryDirectory()
        let reference = directory.appendingPathComponent("reference.gguf")
        var paths: [String] = []
        for index in fixture.shards.indices {
            paths.append(try stage(fixture, index: index, directory: directory).path)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments =
            [
                "python3", script, "--output", reference.path,
                "--expected-bytes", String(fixture.expected.count),
                "--sha256", fixture.plan.expectedSHA256,
            ] + paths
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let message = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus == 127 { throw XCTSkip("python3 is unavailable") }
        XCTAssertEqual(process.terminationStatus, 0, message)
        guard process.terminationStatus == 0 else { return }
        let target = directory.appendingPathComponent("native.gguf")
        let progress = try appendAll(fixture, target: target)
        try GGUFShardAssembler.finalize(plan: fixture.plan, target: target, progress: progress)
        XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: reference))
        XCTAssertEqual(try Data(contentsOf: target), fixture.expected)
    }

    /// Captured ranged prefixes are sufficient; the several-hundred-GiB tensor files
    /// are never downloaded or mapped by this optional real-manifest acceptance test.
    func testPinnedMXFP4HeadersAndPeakWhenFixturesAreProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["DS4_GGUF_HEADER_FIXTURES"] else {
            throw XCTSkip("Set DS4_GGUF_HEADER_FIXTURES to the captured pinned GGUF header directory")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let quant = Quant.q41MXFP4
        let headers = try quant.downloadParts.map { part in
            let prefix = try Data(contentsOf: directory.appendingPathComponent(part.filename + ".header"))
            return try GGUFShardAssembler.parseHeader(prefix, fileBytes: part.bytes)
        }
        let plan = try GGUFShardAssembler.makePlan(
            headers: headers, parts: quant.downloadParts,
            expectedBytes: Int64(quant.ggufBytes),
            expectedSHA256: try XCTUnwrap(quant.sha256))
        let reference = try Data(contentsOf: directory.appendingPathComponent("mxfp4-merged.header"))
        XCTAssertEqual(plan.header, reference)
        XCTAssertEqual(plan.shards.count, 9)
        XCTAssertEqual(plan.shards.last?.endOffset, 501_609_136_128)
        XCTAssertEqual(
            try GGUFShardAssembler.remainingPeakBytes(
                plan: plan,
                stagedBytes: Array(repeating: 0, count: 9)),
            602_989_540_384 + GGUFShardAssembler.diskMargin)
    }

    func testCancelledAppendDoesNotMutateOutputOrDeleteInput() async throws {
        let fixture = try GGUFShardFixture.make()
        let target = try temporaryDirectory().appendingPathComponent("model.gguf")
        let progress = try GGUFShardAssembler.recover(plan: fixture.plan, target: target)
        let input = try stage(fixture, index: 0, directory: target.deletingLastPathComponent())
        let plan = fixture.plan
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try GGUFShardAssembler.append(
                shard: input, index: 0, plan: plan, target: target,
                progress: progress, availableBytes: Int64.max)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
        XCTAssertEqual(try Data(contentsOf: GGUFShardAssembler.assemblyURL(for: target)), plan.header)
        XCTAssertEqual(GGUFShardAssembler.completedShardCount(target: target, expectedSHA256: plan.expectedSHA256), 0)
    }
}

private extension Data {
    mutating func appendLittle<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
