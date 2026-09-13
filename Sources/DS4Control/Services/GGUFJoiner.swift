import CryptoKit
import Foundation

/// Joins the transport parts of the V4.1 Q4 GGUF and verifies digests. Mirrors upstream
/// ds4@bd66c40 `download_model.sh`'s join: adopt `<target>.assembling`, truncate it back to
/// the first part's length, append the second part in 16 MiB blocks, fsync, SHA-256 the
/// result, then rename to the final name. An interrupted join resumes from the partially
/// assembled file (only the smaller tail is rewritten).
///
/// On a digest mismatch the assembled file is deliberately kept so a retry can re-verify or
/// re-append instead of forcing a fresh 480 GiB download; verified parts are never deleted.
enum GGUFJoiner {
    enum Failure: Error, Equatable {
        case missingPart(String)
        case wrongSize(name: String, expected: Int64, actual: Int64)
        case checksumMismatch(name: String)
        case notEnoughDiskSpace(requiredBytes: Int64)
    }

    private static let blockSize = 16 * 1024 * 1024

    /// Streaming SHA-256 (lowercase hex). A one-pass read: ~minutes for the 483 GiB Q4.
    ///
    /// The autorelease pool must be drained per iteration: Foundation's `Data` bridges through
    /// it, and a tight read loop otherwise accumulates every 16 MiB chunk until Jetsam kills
    /// the app — measured at ~200 GiB into a 480 GiB verification.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data? = try autoreleasepool { try handle.read(upToCount: blockSize) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Size (always) and digest (when published) verification for a downloaded artifact.
    static func verify(url: URL, expectedBytes: Int64, expectedSHA256: String?) throws {
        let actual = fileSize(url)
        guard actual == expectedBytes else {
            throw Failure.wrongSize(
                name: url.lastPathComponent, expected: expectedBytes, actual: actual)
        }
        if let expectedSHA256, try sha256(of: url) != expectedSHA256 {
            throw Failure.checksumMismatch(name: url.lastPathComponent)
        }
    }

    /// Resumable in-place join. Requires the parts to be verified by the caller (the service
    /// verifies each part after download); `part1Bytes` is the published first-part size.
    /// The final file appears atomically; `part2` is removed only after a verified rename.
    static func join(
        part1: URL, part2: URL, into target: URL,
        part1Bytes: Int64, expectedBytes: Int64, expectedSHA256: String?, freeSpaceRequired: Int64
    ) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            try verify(url: target, expectedBytes: expectedBytes, expectedSHA256: expectedSHA256)
            try? fm.removeItem(at: part2)
            return
        }
        let assembling = URL(fileURLWithPath: target.path + ".assembling")
        if !fm.fileExists(atPath: assembling.path) {
            guard fm.fileExists(atPath: part1.path) else {
                throw Failure.missingPart(part1.lastPathComponent)
            }
            guard fm.fileExists(atPath: part2.path) else {
                throw Failure.missingPart(part2.lastPathComponent)
            }
            try fm.moveItem(at: part1, to: assembling)
        } else if !fm.fileExists(atPath: part2.path) {
            throw Failure.missingPart(part2.lastPathComponent)
        }

        // Only the tail is appended, so require room for it plus headroom before writing.
        if freeSpaceRequired > 0,
            let values = try? target.deletingLastPathComponent().resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let available = values.volumeAvailableCapacityForImportantUsage,
            Int64(available) < freeSpaceRequired
        {
            throw Failure.notEnoughDiskSpace(requiredBytes: freeSpaceRequired)
        }

        let write = try FileHandle(forWritingTo: assembling)
        do {
            // An interrupted append restarts only the smaller tail, never the 480 GiB prefix.
            try write.truncate(atOffset: UInt64(part1Bytes))
            try write.seekToEnd()
            let read = try FileHandle(forReadingFrom: part2)
            defer { try? read.close() }
            while true {
                let chunk: Data? = try autoreleasepool { try read.read(upToCount: blockSize) }
                guard let chunk, !chunk.isEmpty else { break }
                try write.write(contentsOf: chunk)
            }
            try write.synchronize()
            try write.close()
        } catch {
            try? write.close()
            throw error
        }

        // Verify before publishing; on mismatch the assembled file stays for a retry.
        try verify(url: assembling, expectedBytes: expectedBytes, expectedSHA256: expectedSHA256)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: assembling, to: target)
        try? fm.removeItem(at: part2)
    }
}
