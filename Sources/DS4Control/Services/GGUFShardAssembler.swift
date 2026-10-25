import CryptoKit
import Darwin
import Foundation

/// Restores upstream's page-aligned V4.1 GGUF from standard GGUF v3 split files.
/// Unlike the upstream all-inputs-at-once merger, each verified shard is discarded
/// after its output bytes and recovery journal have both reached durable storage.
/// Callers hold `acquireLock` across recovery, downloading, appending, and publication.
enum GGUFShardAssembler {
    static let alignment: Int64 = 16_384
    static let maximumHeaderBytes = 128 * 1024 * 1024
    static let diskMargin: Int64 = 1 << 30
    private static let blockSize = 16 * 1024 * 1024
    private static let splitKeys: Set<String> = ["split.no", "split.count", "split.tensors.count"]

    enum Failure: Error, Equatable, LocalizedError {
        case incompleteHeader(requiredBytes: Int)
        case invalidHeader(String)
        case invalidPlan(String)
        case missingShard(String)
        case wrongShardSize(name: String, expected: Int64, actual: Int64)
        case shardHeaderMismatch(String)
        case invalidCheckpoint(String)
        case assemblyIdentityMismatch
        case incorrectAppendOrder(expected: Int, actual: Int)
        case notEnoughDiskSpace(requiredBytes: Int64)
        case assemblyLocked
        case finalChecksumMismatch
        case incompleteAssembly

        var errorDescription: String? {
            switch self {
            case .incompleteHeader(let bytes): return "The GGUF header needs at least \(bytes) bytes."
            case .invalidHeader(let reason): return "Invalid GGUF shard header: \(reason)."
            case .invalidPlan(let reason): return "Cannot assemble GGUF shards: \(reason)."
            case .missingShard(let name): return "Missing GGUF shard: \(name)."
            case .wrongShardSize(let name, let expected, let actual):
                return "GGUF shard \(name) has \(actual) bytes; expected \(expected)."
            case .shardHeaderMismatch(let name):
                return "GGUF shard \(name) differs from the planned header. Download that shard again."
            case .invalidCheckpoint(let reason): return "Invalid GGUF recovery journal: \(reason)."
            case .assemblyIdentityMismatch:
                return
                    "The partial GGUF belongs to another assembly. Move the .assembling file and its journal aside, then retry."
            case .incorrectAppendOrder(let expected, let actual):
                return "Expected GGUF shard \(expected + 1), received \(actual + 1)."
            case .notEnoughDiskSpace(let required):
                return "GGUF assembly needs \(required) additional free bytes, including its disk margin."
            case .assemblyLocked: return "Another process is downloading or assembling this GGUF."
            case .finalChecksumMismatch:
                return
                    "The assembled GGUF failed its published SHA-256. Its partial file and journal were kept. Retry to check for disk corruption; if this repeats, move both aside and download again."
            case .incompleteAssembly: return "The GGUF assembly is incomplete. Resume its remaining shards."
            }
        }
    }

    struct Metadata: Sendable {
        let key: String
        let kind: UInt32
        let integer: Int64?
        let string: String?
        let raw: Data
    }

    struct Tensor: Sendable {
        let name: String
        let shape: [UInt64]
        let kind: UInt32
        let relativeOffset: Int64
        let bytes: Int64
    }

    struct Header: Sendable {
        let metadata: [Metadata]
        let tensors: [Tensor]
        let alignment: Int64
        let dataOffset: Int64
        let fileBytes: Int64
        /// The directory before its alignment padding, independent of ranged-read size.
        let raw: Data
        var sha256: String { GGUFShardAssembler.digest(raw) }
    }

    struct ManifestPart: Codable, Equatable, Sendable {
        let filename: String
        let bytes: Int64
        let sha256: String
    }

    struct Segment: Sendable {
        let sourceOffset: Int64
        let destinationOffset: Int64
        let bytes: Int64
        let paddingBytes: Int64
    }

    struct Shard: Sendable {
        let header: Header
        let segments: [Segment]
        let outputOffset: Int64
        let outputBytes: Int64
        var endOffset: Int64 { outputOffset + outputBytes }  // Checked when the plan is built.
    }

    struct Plan: Sendable {
        let header: Data
        let parts: [ManifestPart]
        let shards: [Shard]
        let expectedBytes: Int64
        let expectedSHA256: String
        let fingerprint: String
    }

    struct Progress: Sendable {
        let completedShards: Int
        let completedBytes: Int64
        let isPublished: Bool
        fileprivate let fingerprint: String
        fileprivate let records: [Record]
    }

    fileprivate struct Record: Codable, Equatable, Sendable {
        let endOffset: Int64
        let sha256: String
    }

    private struct Checkpoint: Codable {
        let version: Int
        let fingerprint: String
        let expectedBytes: Int64
        let expectedSHA256: String
        let headerSHA256: String
        let parts: [ManifestPart]
        let completed: [Record]
    }

    final class AssemblyLock: @unchecked Sendable {
        private let mutex = NSLock()
        private var descriptor: Int32
        fileprivate init(_ descriptor: Int32) { self.descriptor = descriptor }
        func release() {
            mutex.lock()
            defer { mutex.unlock() }
            if descriptor >= 0 {
                _ = flock(descriptor, LOCK_UN)
                _ = Darwin.close(descriptor)
                descriptor = -1
            }
        }
        deinit { release() }
    }

    static func assemblyURL(for target: URL) -> URL { URL(fileURLWithPath: target.path + ".assembling") }
    static func checkpointURL(for target: URL) -> URL { URL(fileURLWithPath: target.path + ".assembling.json") }
    static func lockURL(for target: URL) -> URL { URL(fileURLWithPath: target.path + ".assembling.lock") }

    static func acquireLock(target: URL) throws -> AssemblyLock {
        let fd = open(lockURL(for: target).path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw posixFailure() }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            _ = Darwin.close(fd)
            if code == EWOULDBLOCK || code == EAGAIN { throw Failure.assemblyLocked }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return AssemblyLock(fd)
    }

    /// Parse a bounded ranged prefix. Only this error requests more bytes; malformed,
    /// oversized, overflowing, or truncated-file headers never trigger endless retries.
    static func parseHeader(_ data: Data, fileBytes: Int64) throws -> Header {
        guard fileBytes >= 24 else { throw Failure.invalidHeader("file is shorter than its fixed header") }
        var reader = Reader(data: data, fileBytes: fileBytes)
        guard try reader.take(4) == Data("GGUF".utf8), try reader.u32() == 3 else {
            throw Failure.invalidHeader("expected GGUF v3")
        }
        let tensorCount = try reader.u64()
        let metadataCount = try reader.u64()
        guard tensorCount <= 100_000, metadataCount <= 100_000 else {
            throw Failure.invalidHeader("directory count exceeds 100000")
        }
        var metadata: [Metadata] = []
        var keys: Set<String> = []
        var shardAlignment: Int64 = 32
        for _ in 0..<metadataCount {
            try Task.checkCancellation()
            let start = reader.offset
            let key = try reader.string()
            guard keys.insert(key).inserted else { throw Failure.invalidHeader("duplicate metadata key") }
            let kind = try reader.u32()
            let valueStart = reader.offset
            try reader.skipValue(kind: kind)
            let end = reader.offset
            var integer: Int64?
            var string: String?
            if kind == 8 {
                reader.offset = valueStart
                string = try reader.string()
            } else if Reader.scalarSize(kind) != nil {
                reader.offset = valueStart
                integer = try reader.integer(kind: kind)
            }
            reader.offset = end
            if key == "general.alignment" {
                guard let value = integer, value >= 1, value <= alignment,
                    value & (value - 1) == 0
                else { throw Failure.invalidHeader("invalid alignment") }
                shardAlignment = value
            }
            metadata.append(
                Metadata(
                    key: key, kind: kind, integer: integer, string: string,
                    raw: data.subdata(in: start..<end)))
        }
        var tensors: [Tensor] = []
        var nextOffset: Int64 = 0
        for _ in 0..<tensorCount {
            try Task.checkCancellation()
            let name = try reader.string()
            let rank = try reader.u32()
            guard rank >= 1, rank <= 4 else { throw Failure.invalidHeader("invalid tensor rank") }
            var shape: [UInt64] = []
            var elements: UInt64 = 1
            for _ in 0..<rank {
                let dimension = try reader.u64()
                let (product, overflow) = elements.multipliedReportingOverflow(by: dimension)
                guard dimension > 0, !overflow else { throw Failure.invalidHeader("invalid tensor dimensions") }
                elements = product
                shape.append(dimension)
            }
            let kind = try reader.u32()
            let relative = try reader.u64()
            let block: UInt64
            let blockBytes: UInt64
            switch kind {
            case 0: (block, blockBytes) = (1, 4)
            case 1: (block, blockBytes) = (1, 2)
            case 8: (block, blockBytes) = (32, 34)
            case 24: (block, blockBytes) = (1, 1)
            case 39: (block, blockBytes) = (32, 17)
            default: throw Failure.invalidHeader("unsupported MXFP4 tensor type")
            }
            let (bytes, overflow) = (elements / block).multipliedReportingOverflow(by: blockBytes)
            guard shape[0] % block == 0, !overflow, bytes <= UInt64(Int64.max),
                relative == UInt64(nextOffset)
            else { throw Failure.invalidHeader("invalid tensor shape or offset") }
            let tensorBytes = Int64(bytes)
            tensors.append(
                Tensor(
                    name: name, shape: shape, kind: kind,
                    relativeOffset: nextOffset, bytes: tensorBytes))
            nextOffset = try checkedAdd(nextOffset, aligned(tensorBytes, to: shardAlignment))
        }
        let dataOffset = try aligned(Int64(reader.offset), to: shardAlignment)
        guard try checkedAdd(dataOffset, nextOffset) == fileBytes else {
            throw Failure.invalidHeader("tensor extents do not match declared shard size")
        }
        return Header(
            metadata: metadata, tensors: tensors, alignment: shardAlignment,
            dataOffset: dataOffset, fileBytes: fileBytes,
            raw: data.subdata(in: 0..<reader.offset))
    }

    static func makePlan(
        headers: [Header], parts: [QuantPart], expectedBytes: Int64,
        expectedSHA256: String
    ) throws -> Plan {
        guard !headers.isEmpty, headers.count == parts.count, headers.count <= 100_000,
            expectedBytes > 0, isDigest(expectedSHA256)
        else { throw Failure.invalidPlan("invalid manifest or shard count") }
        var manifest: [ManifestPart] = []
        var filenames: Set<String> = []
        for (part, header) in zip(parts, headers) {
            guard part.filename == URL(fileURLWithPath: part.filename).lastPathComponent,
                !part.filename.isEmpty, part.filename != ".", part.filename != "..",
                filenames.insert(part.filename).inserted, part.bytes == header.fileBytes,
                let sha = part.sha256, isDigest(sha)
            else { throw Failure.invalidPlan("invalid shard filename, length, or SHA-256") }
            manifest.append(ManifestPart(filename: part.filename, bytes: part.bytes, sha256: sha.lowercased()))
        }
        let totalTensors = headers.reduce(0) { $0 + $1.tensors.count }
        guard totalTensors <= 100_000 else { throw Failure.invalidPlan("too many combined tensors") }
        var names: Set<String> = []
        for (index, header) in headers.enumerated() {
            let values = Dictionary(uniqueKeysWithValues: header.metadata.map { ($0.key, $0) })
            guard values["split.no"]?.kind == 2, values["split.no"]?.integer == Int64(index),
                values["split.count"]?.kind == 2, values["split.count"]?.integer == Int64(headers.count),
                values["split.tensors.count"]?.kind == 5,
                values["split.tensors.count"]?.integer == Int64(totalTensors)
            else { throw Failure.invalidPlan("incorrect shard order/count or incomplete tensor set") }
            if index > 0, header.metadata.contains(where: { !splitKeys.contains($0.key) }) {
                throw Failure.invalidPlan("metadata outside the first shard")
            }
            for tensor in header.tensors {
                guard names.insert(tensor.name).inserted else { throw Failure.invalidPlan("duplicate tensor name") }
            }
        }
        let firstValues = Dictionary(uniqueKeysWithValues: headers[0].metadata.map { ($0.key, $0) })
        guard firstValues["general.architecture"]?.string == "deepseek41",
            firstValues["general.alignment"]?.kind == 4
        else { throw Failure.invalidPlan("expected DeepSeek V4.1 metadata and explicit alignment") }
        var metadata: [Data] = []
        for field in headers[0].metadata {
            if splitKeys.contains(field.key) { continue }
            guard !field.key.hasPrefix("split.") else { throw Failure.invalidPlan("unknown split metadata") }
            if field.key == "general.alignment" {
                var raw = encodedString(field.key)
                raw.appendLE(UInt32(4))
                raw.appendLE(UInt32(alignment))
                metadata.append(raw)
            } else {
                metadata.append(field.raw)
            }
        }
        var header = Data("GGUF".utf8)
        header.appendLE(UInt32(3))
        header.appendLE(UInt64(totalTensors))
        header.appendLE(UInt64(metadata.count))
        for raw in metadata { header.append(raw) }
        var relativeOffset: Int64 = 0
        for shard in headers {
            for tensor in shard.tensors {
                header.append(encodedString(tensor.name))
                header.appendLE(UInt32(tensor.shape.count))
                for dimension in tensor.shape { header.appendLE(dimension) }
                header.appendLE(tensor.kind)
                header.appendLE(UInt64(relativeOffset))
                relativeOffset = try checkedAdd(relativeOffset, aligned(tensor.bytes, to: alignment))
                guard header.count <= maximumHeaderBytes else {
                    throw Failure.invalidPlan("combined header is too large")
                }
            }
        }
        let paddedHeaderBytes = try aligned(Int64(header.count), to: alignment)
        guard paddedHeaderBytes <= Int64(maximumHeaderBytes) else {
            throw Failure.invalidPlan("combined header is too large")
        }
        header.append(Data(repeating: 0, count: Int(paddedHeaderBytes) - header.count))
        var destination = paddedHeaderBytes
        var shards: [Shard] = []
        for source in headers {
            let start = destination
            var segments: [Segment] = []
            for tensor in source.tensors {
                let padded = try aligned(tensor.bytes, to: alignment)
                segments.append(
                    Segment(
                        sourceOffset: try checkedAdd(source.dataOffset, tensor.relativeOffset),
                        destinationOffset: destination, bytes: tensor.bytes,
                        paddingBytes: padded - tensor.bytes))
                destination = try checkedAdd(destination, padded)
            }
            shards.append(
                Shard(
                    header: source, segments: segments, outputOffset: start,
                    outputBytes: destination - start))
        }
        guard destination == expectedBytes else {
            throw Failure.invalidPlan("merged layout differs from published byte size")
        }
        struct Identity: Encodable {
            let version = 1
            let parts: [ManifestPart]
            let sourceHeaders: [String]
            let outputHeader: String
            let expectedBytes: Int64
            let expectedSHA256: String
        }
        let identity = Identity(
            parts: manifest, sourceHeaders: headers.map(\.sha256),
            outputHeader: digest(header), expectedBytes: expectedBytes,
            expectedSHA256: expectedSHA256.lowercased())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Plan(
            header: header, parts: manifest, shards: shards, expectedBytes: expectedBytes,
            expectedSHA256: expectedSHA256.lowercased(), fingerprint: digest(try encoder.encode(identity)))
    }

    /// Validates every committed output segment once, then discards only the first bad
    /// segment and its tail. A cancelled append never advances the durable journal.
    static func recover(plan: Plan, target: URL) throws -> Progress {
        try Task.checkCancellation()
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            try GGUFJoiner.verify(url: target, expectedBytes: plan.expectedBytes, expectedSHA256: plan.expectedSHA256)
            return Progress(
                completedShards: plan.shards.count, completedBytes: plan.expectedBytes,
                isPublished: true, fingerprint: plan.fingerprint, records: [])
        }
        let assembly = assemblyURL(for: target)
        let journal = checkpointURL(for: target)
        let checkpoint: Checkpoint?
        if fm.fileExists(atPath: journal.path) {
            checkpoint = try readCheckpoint(journal)
            try validate(checkpoint!, plan: plan)
        } else {
            checkpoint = nil
        }
        let existed = fm.fileExists(atPath: assembly.path)
        if !existed { try createExclusive(assembly) }
        let output = try openRegular(assembly, flags: O_RDWR)
        defer { try? output.close() }
        let size = try output.seekToEnd()
        try output.seek(toOffset: 0)
        let prefix = try output.read(upToCount: plan.header.count) ?? Data()
        let headerMatches = prefix == plan.header
        if checkpoint == nil, !plan.header.starts(with: prefix) {
            throw Failure.assemblyIdentityMismatch
        }
        var valid: [Record] = []
        if headerMatches, let checkpoint {
            for (index, record) in checkpoint.completed.enumerated() {
                try Task.checkCancellation()
                let shard = plan.shards[index]
                guard UInt64(record.endOffset) <= size,
                    try hashRange(output, offset: shard.outputOffset, bytes: shard.outputBytes) == record.sha256
                else { break }
                valid.append(record)
            }
        }
        let boundary = valid.last?.endOffset ?? Int64(plan.header.count)
        if !headerMatches {
            try output.seek(toOffset: 0)
            try output.write(contentsOf: plan.header)
        }
        try output.truncate(atOffset: UInt64(boundary))
        try output.synchronize()
        try persist(plan: plan, records: valid, target: target)
        // This also covers a crash between checkpoint replacement and input deletion.
        for part in plan.parts.prefix(valid.count) {
            try removeIfPresent(target.deletingLastPathComponent().appendingPathComponent(part.filename))
        }
        return Progress(
            completedShards: valid.count, completedBytes: boundary, isPublished: false,
            fingerprint: plan.fingerprint, records: valid)
    }

    /// Additional free capacity needed for the remaining sequential download/copy/delete
    /// schedule. Existing output and staged allocations already consume disk capacity and
    /// are subtracted from the peak. Residues from already completed shards remain charged
    /// to current disk usage until the caller actually removes them and inventories again.
    static func remainingPeakBytes(
        plan: Plan, progress: Progress? = nil, stagedBytes: [Int64],
        allocatedOutputBytes: Int64? = nil, marginBytes: Int64 = diskMargin
    ) throws -> Int64 {
        guard stagedBytes.count == plan.parts.count, stagedBytes.allSatisfy({ $0 >= 0 }), marginBytes >= 0 else {
            throw Failure.invalidPlan("invalid allocated-space inventory")
        }
        if let progress { try validate(progress, plan: plan) }
        if progress?.isPublished == true { return 0 }
        let count = progress?.completedShards ?? 0
        let committed = progress?.completedBytes ?? Int64(plan.header.count)
        let allocated = allocatedOutputBytes ?? (progress == nil ? 0 : committed)
        guard allocated >= 0 else { throw Failure.invalidPlan("negative output allocation") }
        // Recovery may free an uncommitted tail; never assume more than the caller's
        // measured allocation can be reclaimed. Sparse committed bytes stay sparse.
        var delta = max(0, committed - allocated)
        var peak = max(0, delta)
        for index in count..<plan.parts.count {
            let part = plan.parts[index]
            let additionalStage = max(0, part.bytes - min(part.bytes, stagedBytes[index]))
            delta = try checkedAdd(delta, additionalStage)
            peak = max(peak, delta)
            delta = try checkedAdd(delta, plan.shards[index].outputBytes)
            peak = max(peak, delta)
            delta = try checkedSubtract(delta, max(part.bytes, stagedBytes[index]))
        }
        return try checkedAdd(peak, marginBytes)
    }

    static func append(
        shard: URL, index: Int, plan: Plan, target: URL, progress: Progress,
        availableBytes: Int64? = nil, deleteStagedShard: Bool = true
    ) throws -> Progress {
        try Task.checkCancellation()
        try validate(progress, plan: plan)
        guard !progress.isPublished, index == progress.completedShards, index < plan.shards.count else {
            throw Failure.incorrectAppendOrder(expected: progress.completedShards, actual: index)
        }
        let fm = FileManager.default
        let part = plan.parts[index]
        let section = plan.shards[index]
        guard fm.fileExists(atPath: shard.path) else { throw Failure.missingShard(shard.lastPathComponent) }
        let input = try openRegular(shard, flags: O_RDONLY)
        defer { try? input.close() }
        let actualSize = try input.seekToEnd()
        guard actualSize == UInt64(part.bytes) else {
            throw Failure.wrongShardSize(
                name: shard.lastPathComponent, expected: part.bytes,
                actual: Int64(clamping: actualSize))
        }
        try input.seek(toOffset: 0)
        let prefix = try input.read(upToCount: section.header.raw.count) ?? Data()
        guard prefix == section.header.raw,
            (try? parseHeader(prefix, fileBytes: part.bytes).sha256) == section.header.sha256
        else { throw Failure.shardHeaderMismatch(shard.lastPathComponent) }
        let required = try checkedAdd(section.outputBytes, diskMargin)
        let free = try availableBytes ?? availableCapacity(at: target)
        guard free >= required else { throw Failure.notEnoughDiskSpace(requiredBytes: required) }
        let assembly = assemblyURL(for: target)
        guard shard.standardizedFileURL != assembly.standardizedFileURL,
            shard.standardizedFileURL != target.standardizedFileURL,
            shard.standardizedFileURL != checkpointURL(for: target).standardizedFileURL
        else { throw Failure.invalidPlan("input aliases assembly state") }
        let output = try openRegular(assembly, flags: O_RDWR)
        defer { try? output.close() }
        let checkpoint = try readCheckpoint(checkpointURL(for: target))
        try validate(checkpoint, plan: plan)
        guard checkpoint.completed == progress.records else {
            throw Failure.invalidCheckpoint("progress is stale; recover before appending")
        }
        guard try output.seekToEnd() >= UInt64(progress.completedBytes) else {
            throw Failure.invalidCheckpoint("partial output shrank; recover before appending")
        }
        try output.truncate(atOffset: UInt64(progress.completedBytes))
        try output.seek(toOffset: UInt64(progress.completedBytes))
        var hasher = SHA256()
        for segment in section.segments {
            try input.seek(toOffset: UInt64(segment.sourceOffset))
            var remaining = segment.bytes
            while remaining > 0 {
                try Task.checkCancellation()
                let count = Int(min(Int64(blockSize), remaining))
                let chunk: Data = try autoreleasepool {
                    guard let chunk = try input.read(upToCount: count), chunk.count == count else {
                        throw Failure.invalidHeader("shard ended during tensor copy")
                    }
                    return chunk
                }
                try output.write(contentsOf: chunk)
                hasher.update(data: chunk)
                remaining -= Int64(chunk.count)
            }
            if segment.paddingBytes > 0 {
                let padding = Data(repeating: 0, count: Int(segment.paddingBytes))
                try output.write(contentsOf: padding)
                hasher.update(data: padding)
            }
        }
        try Task.checkCancellation()
        try output.synchronize()  // Durability order is output, journal, then input deletion.
        var records = progress.records
        records.append(Record(endOffset: section.endOffset, sha256: hex(hasher.finalize())))
        try persist(plan: plan, records: records, target: target)
        if deleteStagedShard { try removeIfPresent(shard) }
        return Progress(
            completedShards: index + 1, completedBytes: section.endOffset,
            isPublished: false, fingerprint: plan.fingerprint, records: records)
    }

    /// Whole-file verification precedes exclusive publication. An existing target is
    /// verified and never replaced. The .verified marker remains the caller's concern.
    static func finalize(plan: Plan, target: URL, progress: Progress) throws {
        try Task.checkCancellation()
        try validate(progress, plan: plan)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            try GGUFJoiner.verify(url: target, expectedBytes: plan.expectedBytes, expectedSHA256: plan.expectedSHA256)
            return
        }
        guard progress.completedShards == plan.shards.count, progress.completedBytes == plan.expectedBytes else {
            throw Failure.incompleteAssembly
        }
        let assembly = assemblyURL(for: target)
        let input = try openRegular(assembly, flags: O_RDONLY)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        guard size == UInt64(plan.expectedBytes) else {
            throw GGUFJoiner.Failure.wrongSize(
                name: assembly.lastPathComponent,
                expected: plan.expectedBytes, actual: Int64(clamping: size))
        }
        guard try hashRange(input, offset: 0, bytes: plan.expectedBytes) == plan.expectedSHA256 else {
            throw Failure.finalChecksumMismatch
        }
        try Task.checkCancellation()
        // link(2), unlike rename, atomically refuses an output created by another process.
        guard link(assembly.path, target.path) == 0 else { throw posixFailure() }
        try synchronizeDirectory(target.deletingLastPathComponent())
        try fm.removeItem(at: assembly)
        try? fm.removeItem(at: checkpointURL(for: target))
        try synchronizeDirectory(target.deletingLastPathComponent())
    }

    /// An intentionally untrusted, bounded UI hint. Recovery remains authoritative.
    static func completedShardCount(target: URL, expectedSHA256: String) -> Int {
        guard let checkpoint = try? readCheckpoint(checkpointURL(for: target)), checkpoint.version == 1,
            checkpoint.expectedSHA256 == expectedSHA256.lowercased(), isDigest(checkpoint.fingerprint),
            isDigest(checkpoint.headerSHA256), checkpoint.expectedBytes > 0,
            checkpoint.parts.count <= 100_000, checkpoint.completed.count <= checkpoint.parts.count,
            checkpoint.completed.allSatisfy({
                isDigest($0.sha256) && $0.endOffset > 0 && $0.endOffset <= checkpoint.expectedBytes
            })
        else { return 0 }
        var last: Int64 = 0
        for record in checkpoint.completed {
            guard record.endOffset >= last else { return 0 }
            last = record.endOffset
        }
        return checkpoint.completed.count
    }

    private static func validate(_ progress: Progress, plan: Plan) throws {
        guard progress.fingerprint == plan.fingerprint, progress.completedShards >= 0,
            progress.completedShards <= plan.shards.count,
            progress.completedBytes
                == (progress.completedShards == 0
                    ? Int64(plan.header.count) : plan.shards[progress.completedShards - 1].endOffset),
            progress.isPublished || progress.records.count == progress.completedShards
        else { throw Failure.invalidCheckpoint("progress does not match plan") }
    }

    private static func validate(_ checkpoint: Checkpoint, plan: Plan) throws {
        guard checkpoint.version == 1, checkpoint.fingerprint == plan.fingerprint,
            checkpoint.expectedBytes == plan.expectedBytes, checkpoint.expectedSHA256 == plan.expectedSHA256,
            checkpoint.headerSHA256 == digest(plan.header), checkpoint.parts == plan.parts,
            checkpoint.completed.count <= plan.shards.count
        else { throw Failure.assemblyIdentityMismatch }
        for (index, record) in checkpoint.completed.enumerated() {
            guard record.endOffset == plan.shards[index].endOffset, isDigest(record.sha256) else {
                throw Failure.invalidCheckpoint("incorrect segment boundary or digest")
            }
        }
    }

    private static func persist(plan: Plan, records: [Record], target: URL) throws {
        let checkpoint = Checkpoint(
            version: 1, fingerprint: plan.fingerprint,
            expectedBytes: plan.expectedBytes, expectedSHA256: plan.expectedSHA256,
            headerSHA256: digest(plan.header), parts: plan.parts, completed: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(checkpoint)
        let journal = checkpointURL(for: target)
        // The assembly lock owns this deterministic, uncommitted scratch name. A crash
        // cannot accumulate UUID-named journal files across retries.
        let temporary = URL(fileURLWithPath: journal.path + ".tmp")
        try removeIfPresent(temporary)
        try createExclusive(temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard rename(temporary.path, journal.path) == 0 else { throw posixFailure() }
        try synchronizeDirectory(target.deletingLastPathComponent())
    }

    private static func readCheckpoint(_ url: URL) throws -> Checkpoint {
        let handle = try openRegular(url, flags: O_RDONLY)
        defer { try? handle.close() }
        let limit = 32 * 1024 * 1024
        guard try handle.seekToEnd() <= UInt64(limit) else {
            throw Failure.invalidCheckpoint("journal exceeds size limit")
        }
        try handle.seek(toOffset: 0)
        guard let data = try handle.read(upToCount: limit) else { throw Failure.invalidCheckpoint("empty journal") }
        do { return try JSONDecoder().decode(Checkpoint.self, from: data) } catch {
            throw Failure.invalidCheckpoint("cannot decode journal")
        }
    }

    private static func hashRange(_ handle: FileHandle, offset: Int64, bytes: Int64) throws -> String {
        try handle.seek(toOffset: UInt64(offset))
        var remaining = bytes
        var hasher = SHA256()
        while remaining > 0 {
            try Task.checkCancellation()
            let count = Int(min(Int64(blockSize), remaining))
            let chunk: Data = try autoreleasepool {
                guard let data = try handle.read(upToCount: count), data.count == count else {
                    throw Failure.invalidCheckpoint("output ended while validating a segment")
                }
                return data
            }
            hasher.update(data: chunk)
            remaining -= Int64(chunk.count)
        }
        return hex(hasher.finalize())
    }

    private static func availableCapacity(at target: URL) throws -> Int64 {
        let values = try target.deletingLastPathComponent().resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey
        ])
        guard let bytes = values.volumeAvailableCapacityForImportantUsage else {
            throw Failure.invalidPlan("cannot determine free disk capacity")
        }
        return bytes
    }

    private static func createExclusive(_ url: URL) throws {
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw posixFailure() }
        guard Darwin.close(fd) == 0 else { throw posixFailure() }
    }

    private static func removeIfPresent(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return }
            throw posixFailure()
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw Failure.invalidCheckpoint("refusing to remove non-regular file \(url.lastPathComponent)")
        }
        // unlink never recursively removes a directory, even if the path is replaced
        // between lstat and deletion. The assembly lock excludes cooperating writers.
        guard unlink(url.path) == 0 else {
            if errno == ENOENT { return }
            throw posixFailure()
        }
    }

    private static func openRegular(_ url: URL, flags: Int32) throws -> FileHandle {
        let fd = open(url.path, flags | O_NOFOLLOW)
        guard fd >= 0 else { throw posixFailure() }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let error = posixFailure()
            _ = Darwin.close(fd)
            throw error
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            _ = Darwin.close(fd)
            throw Failure.invalidCheckpoint("expected a regular file at \(url.lastPathComponent)")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw posixFailure() }
        defer { _ = Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw posixFailure() }
    }

    private static func posixFailure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    private static func digest(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
    private static func encodedString(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        var data = Data()
        data.appendLE(UInt64(bytes.count))
        data.append(bytes)
        return data
    }
    private static func checkedAdd(_ left: Int64, _ right: Int64) throws -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        guard !overflow else { throw Failure.invalidHeader("integer overflow") }
        return value
    }
    private static func checkedSubtract(_ left: Int64, _ right: Int64) throws -> Int64 {
        let (value, overflow) = left.subtractingReportingOverflow(right)
        guard !overflow else { throw Failure.invalidHeader("integer overflow") }
        return value
    }
    private static func aligned(_ bytes: Int64, to alignment: Int64) throws -> Int64 {
        let rounded = try checkedAdd(bytes, alignment - 1)
        return rounded / alignment * alignment
    }

    private struct Reader {
        let data: Data
        let fileBytes: Int64
        var offset = 0

        mutating func take(_ count: Int) throws -> Data {
            try require(count)
            let result = data.subdata(in: offset..<(offset + count))
            offset += count
            return result
        }
        mutating func require(_ count: Int) throws {
            let (end, overflow) = offset.addingReportingOverflow(count)
            guard count >= 0, !overflow, end <= maximumHeaderBytes, Int64(end) <= fileBytes else {
                throw Failure.invalidHeader("metadata/header extent exceeds limit or file size")
            }
            guard end <= data.count else { throw Failure.incompleteHeader(requiredBytes: end) }
        }
        mutating func skip(_ count: UInt64) throws {
            guard count <= UInt64(maximumHeaderBytes) else {
                throw Failure.invalidHeader("metadata extent exceeds limit")
            }
            try require(Int(count))
            offset += Int(count)
        }
        mutating func u8() throws -> UInt8 { try take(1)[0] }
        mutating func u16() throws -> UInt16 { try number(UInt16.self) }
        mutating func u32() throws -> UInt32 { try number(UInt32.self) }
        mutating func u64() throws -> UInt64 { try number(UInt64.self) }
        mutating func number<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let bytes = try take(MemoryLayout<T>.size)
            return bytes.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
        }
        mutating func string() throws -> String {
            let length = try u64()
            guard length <= UInt64(maximumHeaderBytes) else {
                throw Failure.invalidHeader("string exceeds header limit")
            }
            guard let value = String(data: try take(Int(length)), encoding: .utf8) else {
                throw Failure.invalidHeader("invalid UTF-8 string")
            }
            return value
        }
        static func scalarSize(_ kind: UInt32) -> UInt64? {
            switch kind {
            case 0, 1, 7: return 1
            case 2, 3: return 2
            case 4, 5, 6: return 4
            case 10, 11, 12: return 8
            default: return nil
            }
        }
        mutating func integer(kind: UInt32) throws -> Int64? {
            switch kind {
            case 0: return Int64(try u8())
            case 1: return Int64(Int8(bitPattern: try u8()))
            case 2: return Int64(try u16())
            case 3: return Int64(Int16(bitPattern: try u16()))
            case 4: return Int64(try u32())
            case 5: return Int64(Int32(bitPattern: try u32()))
            case 10:
                let value = try u64()
                return value <= UInt64(Int64.max) ? Int64(value) : nil
            case 11: return Int64(bitPattern: try u64())
            default:
                try skip(Self.scalarSize(kind) ?? 0)
                return nil
            }
        }
        mutating func skipValue(kind: UInt32, depth: Int = 0) throws {
            guard depth <= 4 else { throw Failure.invalidHeader("nested metadata exceeds depth limit") }
            if let size = Self.scalarSize(kind) { try skip(size); return }
            if kind == 8 { let length = try u64(); try skip(length); return }
            guard kind == 9 else { throw Failure.invalidHeader("unsupported metadata type") }
            let element = try u32()
            let count = try u64()
            if let size = Self.scalarSize(element) {
                let (bytes, overflow) = count.multipliedReportingOverflow(by: size)
                guard !overflow else { throw Failure.invalidHeader("array extent overflow") }
                try skip(bytes)
            } else {
                guard element == 8 || element == 9, count <= UInt64(maximumHeaderBytes / 8) else {
                    throw Failure.invalidHeader("invalid metadata array length or type")
                }
                for _ in 0..<count { try skipValue(kind: element, depth: depth + 1) }
            }
        }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
