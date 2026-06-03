import XCTest

@testable import DS4Control

final class ChunkBitmapTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("chunkbitmap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func partURL() -> URL { dir.appendingPathComponent("model.gguf.part") }

    /// Create, mark a few chunks, reopen with the *same* header → those chunks are still complete and
    /// `completedBytes` sums them. Exercises the persist + load round-trip.
    func testRoundTrip() throws {
        let total: Int64 = 1000
        let chunkSize: Int64 = 100  // 10 full chunks
        let bm = try ChunkBitmap.loadOrCreate(
            partURL: partURL(), total: total, chunkSize: chunkSize, seedContiguousBytes: 0)
        XCTAssertEqual(bm.chunkCount, 10)
        XCTAssertEqual(bm.completedBytes(), 0)

        try bm.markComplete(0)
        try bm.markComplete(3)
        try bm.markComplete(7)
        XCTAssertEqual(bm.completedBytes(), 300)
        XCTAssertEqual(bm.completedIndices(), [0, 3, 7])

        // Reopen with the identical header — must adopt the persisted bytes.
        let reopened = try ChunkBitmap.loadOrCreate(
            partURL: partURL(), total: total, chunkSize: chunkSize, seedContiguousBytes: 0)
        XCTAssertTrue(reopened.isComplete(0))
        XCTAssertTrue(reopened.isComplete(3))
        XCTAssertTrue(reopened.isComplete(7))
        XCTAssertFalse(reopened.isComplete(1))
        XCTAssertEqual(reopened.completedBytes(), 300)
        XCTAssertEqual(reopened.completedIndices(), [0, 3, 7])
    }

    /// When `total` isn't a multiple of `chunkSize`, the last chunk is a short remainder. Marking it
    /// must give `completedBytes` exactly that remainder (and never exceed `total`).
    func testLastChunkClamp() throws {
        let total: Int64 = 950  // 9 full chunks of 100 + a 50-byte tail = 10 chunks
        let chunkSize: Int64 = 100
        let bm = try ChunkBitmap.loadOrCreate(
            partURL: partURL(), total: total, chunkSize: chunkSize, seedContiguousBytes: 0)
        XCTAssertEqual(bm.chunkCount, 10)

        let last = bm.chunkCount - 1
        try bm.markComplete(last)
        XCTAssertEqual(bm.completedBytes(), 50)  // the 50-byte remainder, not 100
        XCTAssertLessThanOrEqual(bm.completedBytes(), total)

        // All chunks complete → exactly total, no overshoot from the short tail.
        for i in 0..<bm.chunkCount { try bm.markComplete(i) }
        XCTAssertEqual(bm.completedBytes(), total)
    }

    /// A sidecar whose header disagrees on total *or* chunkSize must be rejected: reopening with a
    /// different layout returns a fresh all-pending bitmap with no carried-over completions.
    func testStaleSidecarRejection() throws {
        let bm = try ChunkBitmap.loadOrCreate(
            partURL: partURL(), total: 1000, chunkSize: 100, seedContiguousBytes: 0)
        try bm.markComplete(0)
        try bm.markComplete(1)
        XCTAssertEqual(bm.completedBytes(), 200)

        // Different total → reject, start clean.
        let differentTotal = try ChunkBitmap.loadOrCreate(
            partURL: partURL(), total: 2000, chunkSize: 100, seedContiguousBytes: 0)
        XCTAssertEqual(differentTotal.completedBytes(), 0)
        XCTAssertTrue(differentTotal.completedIndices().isEmpty)
        XCTAssertEqual(differentTotal.chunkCount, 20)

        // Re-seed a known state, then reopen with a different chunkSize → also reject.
        let reseed = try ChunkBitmap.loadOrCreate(
            partURL: partURL(), total: 2000, chunkSize: 100, seedContiguousBytes: 0)
        try reseed.markComplete(5)
        XCTAssertEqual(reseed.completedBytes(), 100)

        let differentChunkSize = try ChunkBitmap.loadOrCreate(
            partURL: partURL(), total: 2000, chunkSize: 250, seedContiguousBytes: 0)
        XCTAssertEqual(differentChunkSize.completedBytes(), 0)
        XCTAssertTrue(differentChunkSize.completedIndices().isEmpty)
        XCTAssertEqual(differentChunkSize.chunkCount, 8)
    }

    /// Seeding from a legacy contiguous `.part`: `seedContiguousBytes = 2.5 chunks` must mark exactly
    /// the 2 leading *whole* chunks complete (the partial third chunk is not durably whole → pending).
    func testSeedContiguousBytes() throws {
        let chunkSize: Int64 = 100
        let bm = try ChunkBitmap.loadOrCreate(
            partURL: partURL(), total: 1000, chunkSize: chunkSize, seedContiguousBytes: 250)
        XCTAssertTrue(bm.isComplete(0))
        XCTAssertTrue(bm.isComplete(1))
        XCTAssertFalse(bm.isComplete(2))
        XCTAssertEqual(bm.completedIndices(), [0, 1])
        XCTAssertEqual(bm.completedBytes(), 200)

        // The seed only applies on a *fresh* create; reopening a matching sidecar adopts the persisted
        // bytes and ignores the seed argument.
        let reopened = try ChunkBitmap.loadOrCreate(
            partURL: partURL(), total: 1000, chunkSize: chunkSize, seedContiguousBytes: 900)
        XCTAssertEqual(reopened.completedIndices(), [0, 1])
    }

    /// `delete()` removes the sidecar so a stale bitmap never outlives its `.part`.
    func testDelete() throws {
        let bm = try ChunkBitmap.loadOrCreate(
            partURL: partURL(), total: 500, chunkSize: 100, seedContiguousBytes: 0)
        let sidecar = URL(fileURLWithPath: partURL().path + ".dl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        bm.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
    }
}
