import CryptoKit
import XCTest

@testable import DS4Control

final class GGUFJoinerTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The digest pass must report read progress: the UI advances a verification bar with it
    /// (minutes-long passes on the V4.1 quants otherwise look like a frozen download).
    func testSha256ReportsReadProgress() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("zeros.bin")
        let total = Int64(40 * 1024 * 1024)  // three blocks at the production 16 MiB block size
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(total))
        try handle.close()

        var reported: [Int64] = []
        _ = try GGUFJoiner.sha256(of: url, onProgress: { reported.append($0) })

        XCTAssertFalse(reported.isEmpty, "the hash pass must report progress")
        XCTAssertEqual(reported, reported.sorted(), "progress must be monotonic")
        XCTAssertEqual(reported.last, total, "the final callback must report the whole file")
    }

    /// `verify` must forward the hash-progress callback; without a published digest it is the
    /// instant size-only check and reports nothing.
    func testVerifyForwardsHashProgress() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("blob.bin")
        let data = Data(repeating: 0x5A, count: 3 * 1024 * 1024)
        try data.write(to: url)

        var reported: [Int64] = []
        try GGUFJoiner.verify(
            url: url, expectedBytes: Int64(data.count), expectedSHA256: sha256Hex(data),
            onHashProgress: { reported.append($0) })
        XCTAssertEqual(reported.last, Int64(data.count))

        var none: [Int64] = []
        try GGUFJoiner.verify(
            url: url, expectedBytes: Int64(data.count), expectedSHA256: nil,
            onHashProgress: { none.append($0) })
        XCTAssertTrue(none.isEmpty, "a digest-less quant verifies by size only")
    }

    func testJoinAppendsSecondPartAndVerifiesDigest() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = Data(repeating: 0xAB, count: 64 * 1024)
        let b = Data(repeating: 0xCD, count: 16 * 1024)
        let part1 = dir.appendingPathComponent("x.gguf.part1")
        let part2 = dir.appendingPathComponent("x.gguf.part2")
        let target = dir.appendingPathComponent("x.gguf")
        try a.write(to: part1)
        try b.write(to: part2)

        try GGUFJoiner.join(
            part1: part1, part2: part2, into: target, part1Bytes: Int64(a.count),
            expectedBytes: Int64(a.count + b.count), expectedSHA256: sha256Hex(a + b),
            freeSpaceRequired: 0)

        XCTAssertEqual(try Data(contentsOf: target), a + b)
        XCTAssertFalse(FileManager.default.fileExists(atPath: part1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: part2.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: target.path + ".assembling"))
    }

    func testJoinResumesInterruptedAppend() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = Data(repeating: 0x11, count: 32 * 1024)
        let b = Data(repeating: 0x22, count: 8 * 1024)
        let part2 = dir.appendingPathComponent("x.gguf.part2")
        let target = dir.appendingPathComponent("x.gguf")
        let assembling = URL(fileURLWithPath: target.path + ".assembling")
        // A previous join adopted part1 and appended only the first byte of part2.
        try (a + b.prefix(1)).write(to: assembling)
        try b.write(to: part2)
        // part1 no longer exists (it was renamed into the assembling file).

        try GGUFJoiner.join(
            part1: dir.appendingPathComponent("x.gguf.part1"), part2: part2, into: target,
            part1Bytes: Int64(a.count), expectedBytes: Int64(a.count + b.count),
            expectedSHA256: sha256Hex(a + b), freeSpaceRequired: 0)

        XCTAssertEqual(try Data(contentsOf: target), a + b)
        XCTAssertFalse(FileManager.default.fileExists(atPath: assembling.path))
    }

    func testJoinKeepsAssembledFileOnChecksumMismatch() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = Data(repeating: 0x33, count: 4096)
        let b = Data(repeating: 0x44, count: 4096)
        let part1 = dir.appendingPathComponent("x.gguf.part1")
        let part2 = dir.appendingPathComponent("x.gguf.part2")
        let target = dir.appendingPathComponent("x.gguf")
        try a.write(to: part1)
        try b.write(to: part2)

        XCTAssertThrowsError(
            try GGUFJoiner.join(
                part1: part1, part2: part2, into: target, part1Bytes: Int64(a.count),
                expectedBytes: Int64(a.count + b.count),
                expectedSHA256: sha256Hex(a + b + Data([0])),  // wrong on purpose
                freeSpaceRequired: 0)
        ) { error in
            XCTAssertEqual(
                error as? GGUFJoiner.Failure, .checksumMismatch(name: "x.gguf.assembling"))
        }
        // The assembled file and the tail part are kept so a retry can re-verify/re-append.
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path + ".assembling"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: part2.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target.path + ".assembling")), a + b)
    }

    func testJoinThrowsMissingPart() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("x.gguf")
        XCTAssertThrowsError(
            try GGUFJoiner.join(
                part1: dir.appendingPathComponent("x.gguf.part1"),
                part2: dir.appendingPathComponent("x.gguf.part2"), into: target,
                part1Bytes: 16, expectedBytes: 32, expectedSHA256: nil, freeSpaceRequired: 0)
        ) { error in
            XCTAssertEqual(error as? GGUFJoiner.Failure, .missingPart("x.gguf.part1"))
        }
    }

    func testVerifyRejectsWrongSize() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("part")
        try Data(repeating: 1, count: 100).write(to: url)
        XCTAssertThrowsError(
            try GGUFJoiner.verify(url: url, expectedBytes: 101, expectedSHA256: nil)
        ) { error in
            XCTAssertEqual(
                error as? GGUFJoiner.Failure,
                .wrongSize(name: "part", expected: 101, actual: 100))
        }
        // Correct size + digest passes; nil digest means size-only.
        try GGUFJoiner.verify(url: url, expectedBytes: 100, expectedSHA256: nil)
        XCTAssertEqual(try GGUFJoiner.sha256(of: url), sha256Hex(Data(repeating: 1, count: 100)))
    }
}
