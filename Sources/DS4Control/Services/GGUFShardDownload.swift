import Foundation

/// Drives one-shard-at-a-time downloads. Tensor reconstruction and durable checkpoints
/// belong to the assembler; HTTP downloads continue to use the native chunk bitmap.
enum GGUFShardDownload {
    typealias Report = @Sendable (DownloadProgress.Phase, String, Int64) -> Void

    struct Artifact: Sendable {
        let repo: String
        let downloadRevision: String
        let ggufFilename: String
        let ggufBytes: Int64
        let sha256: String
        let downloadParts: [QuantPart]
        var downloadBytes: Int64 { downloadParts.reduce(0) { $0 + $1.bytes } }
    }

    static func run(
        quant: Quant,
        directory: URL, token: String?, highPerformance: Bool,
        fetchFile: SupervisorService.FetchFile, fetchPrefix: SupervisorService.FetchPrefix,
        onProgress: @escaping Report
    ) async throws {
        guard let sha256 = quant.sha256 else { throw HFDownloader.Failure.http(-3) }
        try await run(
            artifact: Artifact(
                repo: quant.repo, downloadRevision: quant.downloadRevision,
                ggufFilename: quant.ggufFilename, ggufBytes: Int64(quant.ggufBytes),
                sha256: sha256, downloadParts: quant.downloadParts),
            directory: directory, token: token, highPerformance: highPerformance,
            fetchFile: fetchFile, fetchPrefix: fetchPrefix, onProgress: onProgress)
    }

    static func run(
        artifact quant: Artifact, directory: URL, token: String?, highPerformance: Bool,
        fetchFile: SupervisorService.FetchFile, fetchPrefix: SupervisorService.FetchPrefix,
        availableSpace: @Sendable (URL) throws -> Int64 = { try availableBytes($0) },
        onProgress: @escaping Report
    ) async throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(quant.ggufFilename)
        let lock = try GGUFShardAssembler.acquireLock(target: target)
        defer { lock.release() }
        // Crash after publication but before the supervisor's marker: reverify, don't
        // re-download inputs which successful incremental assembly already removed.
        if FileManager.default.fileExists(atPath: target.path) {
            try requireRegularFileIfPresent(target)
            onProgress(.verifying, quant.ggufFilename, quant.downloadBytes)
            do {
                try GGUFJoiner.verify(
                    url: target, expectedBytes: Int64(quant.ggufBytes), expectedSHA256: quant.sha256)
                return
            } catch let error as GGUFJoiner.Failure {
                switch error {
                case .wrongSize, .checksumMismatch:
                    try removeRegularFileIfPresent(target)
                    try removeRegularFileIfPresent(target.appendingPathExtension("verified"))
                default: break
                }
                throw error
            }
        }
        onProgress(.preparing, quant.ggufFilename, 0)
        let parts = quant.downloadParts
        var headers: [GGUFShardAssembler.Header] = []
        for part in parts {
            try Task.checkCancellation()
            var count = min(16 * 1024, Int(part.bytes))
            while true {
                let data = try await fetchPrefix(
                    quant.repo, quant.downloadRevision, part.filename, count, part.bytes, token)
                guard data.count == count else { throw HFDownloader.Failure.http(-3) }
                do {
                    headers.append(try GGUFShardAssembler.parseHeader(data, fileBytes: part.bytes))
                    break
                } catch GGUFShardAssembler.Failure.incompleteHeader(let requiredBytes) {
                    let next = max(requiredBytes, count * 2)
                    guard next > count, next <= 128 * 1024 * 1024, Int64(next) <= part.bytes else {
                        throw HFDownloader.Failure.http(-3)
                    }
                    count = next
                }
            }
        }
        let sha = quant.sha256
        let plan = try GGUFShardAssembler.makePlan(
            headers: headers, parts: parts, expectedBytes: Int64(quant.ggufBytes), expectedSHA256: sha)
        onProgress(.verifying, quant.ggufFilename, 0)
        var progress = try GGUFShardAssembler.recover(plan: plan, target: target)
        for part in parts.prefix(progress.completedShards) {
            try removeStagingSidecars(part: part, directory: directory)
        }
        for index in progress.completedShards..<parts.count {
            try Task.checkCancellation()
            let stagedBytes = parts.map { part in
                allocatedBytes(directory.appendingPathComponent(part.filename))
                    + allocatedBytes(directory.appendingPathComponent(part.filename + ".part"))
            }
            let needed = try GGUFShardAssembler.remainingPeakBytes(
                plan: plan, progress: progress, stagedBytes: stagedBytes,
                allocatedOutputBytes: allocatedBytes(GGUFShardAssembler.assemblyURL(for: target)))
            guard try availableSpace(directory) >= needed else {
                throw GGUFJoiner.Failure.notEnoughDiskSpace(requiredBytes: needed)
            }
            let part = parts[index]
            let staged = directory.appendingPathComponent(part.filename)
            let done = parts.prefix(index).reduce(Int64(0)) { $0 + $1.bytes }
            onProgress(.downloading, part.filename, done)
            for suffix in ["", ".part", ".part.dl"] {
                try requireRegularFileIfPresent(directory.appendingPathComponent(part.filename + suffix))
            }
            try await fetchFile(
                quant.repo, quant.downloadRevision, part.filename, directory, token, highPerformance
            ) { received, _ in
                onProgress(.downloading, part.filename, done + received)
            }
            onProgress(.verifying, part.filename, done + part.bytes)
            do {
                try GGUFJoiner.verify(url: staged, expectedBytes: part.bytes, expectedSHA256: part.sha256)
            } catch let error as GGUFJoiner.Failure {
                switch error {
                case .wrongSize, .checksumMismatch:
                    for suffix in ["", ".part", ".part.dl", ".verified"] {
                        try removeRegularFileIfPresent(directory.appendingPathComponent(part.filename + suffix))
                    }
                default: break
                }
                throw error
            }
            onProgress(.assembling, part.filename, done + part.bytes)
            progress = try GGUFShardAssembler.append(
                shard: staged, index: index, plan: plan, target: target, progress: progress)
            // Only reached after the output and its checkpoint are durable.
            try removeStagingSidecars(part: part, directory: directory)
        }
        onProgress(.verifying, quant.ggufFilename, quant.downloadBytes)
        try GGUFShardAssembler.finalize(plan: plan, target: target, progress: progress)
    }

    /// Failure to reclaim staging must stop the schedule: the peak-space calculation
    /// assumes each stage is removed before downloading the next one.
    private static func removeStagingSidecars(part: QuantPart, directory: URL) throws {
        for suffix in [".part", ".part.dl", ".verified"] {
            try removeRegularFileIfPresent(directory.appendingPathComponent(part.filename + suffix))
        }
    }

    private static func requireRegularFileIfPresent(_ url: URL) throws {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return
        }
    }

    private static func removeRegularFileIfPresent(_ url: URL) throws {
        try requireRegularFileIfPresent(url)
        do { try FileManager.default.removeItem(at: url) } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
        { return }
    }

    static func allocatedBytes(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else {
            return 0
        }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }

    static func availableBytes(_ directory: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        return (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }
}
