import Foundation

/// A crash-safe sidecar that records which fixed-size chunks of a parallel download are *durably*
/// complete, so a relaunch resumes instead of refetching hundreds of GB. Parallel workers write
/// chunks out-of-order straight to their offset in `<file>.part`, so the `.part` is sparse and its
/// size tells us nothing about progress — this bitmap is the source of truth for what's safely on
/// disk.
///
/// On-disk layout (sidecar path = `<part URL>.dl`):
/// ```
/// "DS4DL1\n"            magic (7 bytes)
/// total      Int64 LE   the resolved final-file size this bitmap describes
/// chunkSize  Int64 LE   the chunk size this bitmap was built with
/// status[0]  UInt8      0 = pending, 1 = complete   (one byte per chunk, chunkCount of them)
/// status[1]  UInt8
/// …
/// ```
/// The header lets a *stale* sidecar (left over from a download with a different total or chunk
/// size — e.g. the user changed the High-Performance toggle, or the remote file changed) be
/// detected and rejected, so we never resume against an incompatible layout: we just start clean.
///
/// A chunk's byte is flipped to `1` only *after* the chunk fully downloaded and the `.part` was
/// fsynced, and `markComplete` itself fsyncs the sidecar — so a crash or power loss can at worst
/// re-fetch an in-flight chunk (idempotent: same offset, overwritten), never lose a completed one.
///
/// Thread-safety: parallel workers call `markComplete`/`isComplete` concurrently from the download
/// task group, so all in-memory state and the shared `FileHandle` are guarded by a single `NSLock`.
final class ChunkBitmap: @unchecked Sendable {
    /// Magic + format version. Bumping the suffix invalidates every old sidecar.
    private static let magic = Data("DS4DL1\n".utf8)
    /// Bytes before the per-chunk status array: magic + total(Int64) + chunkSize(Int64).
    private static let headerLen = magic.count + 8 + 8

    /// The resolved final-file size this bitmap describes.
    let total: Int64
    /// The chunk size this bitmap was built with.
    let chunkSize: Int64
    /// Number of chunks: `ceil(total / chunkSize)`.
    let chunkCount: Int

    private let sidecarURL: URL
    private let lock = NSLock()
    /// One byte per chunk: 0 = pending, 1 = complete. Guarded by `lock`.
    private var status: [UInt8]
    /// Open for in-place single-byte writes at `headerLen + index`. Guarded by `lock`.
    private var handle: FileHandle?

    private init(sidecarURL: URL, total: Int64, chunkSize: Int64, status: [UInt8], handle: FileHandle) {
        self.sidecarURL = sidecarURL
        self.total = total
        self.chunkSize = chunkSize
        self.chunkCount = status.count
        self.status = status
        self.handle = handle
    }

    /// Load the sidecar for `partURL` if it matches `total`/`chunkSize`, else create a fresh one.
    ///
    /// A fresh bitmap is all-pending *except* its first `floor(seedContiguousBytes / chunkSize)`
    /// chunks, which are seeded complete: a legacy contiguous `.part` of size `seedContiguousBytes`
    /// already has those leading *whole* chunks durably on disk, so we keep them rather than
    /// refetch. (A partial trailing chunk is *not* seeded — only fully-present chunks count.)
    static func loadOrCreate(
        partURL: URL, total: Int64, chunkSize: Int64, seedContiguousBytes: Int64
    ) throws -> ChunkBitmap {
        precondition(total >= 0 && chunkSize > 0, "ChunkBitmap requires total >= 0 and chunkSize > 0")
        let sidecarURL = URL(fileURLWithPath: partURL.path + ".dl")
        let chunkCount = Int((total + chunkSize - 1) / chunkSize)

        // Try to adopt an existing sidecar whose header matches exactly.
        if let existing = try loadMatching(
            sidecarURL: sidecarURL, total: total, chunkSize: chunkSize, chunkCount: chunkCount)
        {
            return existing
        }

        // Create fresh: all pending, then seed the leading whole chunks.
        var status = [UInt8](repeating: 0, count: chunkCount)
        let seededChunks = min(Int(max(seedContiguousBytes, 0) / chunkSize), chunkCount)
        for i in 0..<seededChunks { status[i] = 1 }

        var bytes = headerBytes(total: total, chunkSize: chunkSize)
        bytes.append(contentsOf: status)
        // A stale sidecar of a different length must be fully replaced, so write atomically.
        try bytes.write(to: sidecarURL, options: .atomic)

        let handle = try FileHandle(forWritingTo: sidecarURL)
        try handle.synchronize()  // durably commit the fresh sidecar before any chunks land.
        return ChunkBitmap(
            sidecarURL: sidecarURL, total: total, chunkSize: chunkSize, status: status, handle: handle)
    }

    /// Load an existing sidecar only if its magic + total + chunkSize match; otherwise return nil so
    /// the caller starts clean. A short/corrupt file is treated as "doesn't match".
    private static func loadMatching(
        sidecarURL: URL, total: Int64, chunkSize: Int64, chunkCount: Int
    ) throws -> ChunkBitmap? {
        guard let data = try? Data(contentsOf: sidecarURL) else { return nil }
        guard data.count == headerLen + chunkCount else { return nil }
        guard data.prefix(magic.count) == magic else { return nil }
        let storedTotal = readInt64LE(data, at: magic.count)
        let storedChunkSize = readInt64LE(data, at: magic.count + 8)
        guard storedTotal == total, storedChunkSize == chunkSize else { return nil }

        let status = [UInt8](data.suffix(chunkCount))
        let handle = try FileHandle(forWritingTo: sidecarURL)
        return ChunkBitmap(
            sidecarURL: sidecarURL, total: total, chunkSize: chunkSize, status: status, handle: handle)
    }

    /// True if chunk `index` is recorded complete. Out-of-range reads return false.
    func isComplete(_ index: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard index >= 0 && index < status.count else { return false }
        return status[index] == 1
    }

    /// A snapshot of the completed chunk indices — the chunk generator's skip set.
    func completedIndices() -> Set<Int> {
        lock.lock()
        defer { lock.unlock() }
        var set = Set<Int>()
        for (i, b) in status.enumerated() where b == 1 { set.insert(i) }
        return set
    }

    /// Record chunk `index` complete: flip the in-memory byte, persist *that one byte* in place, and
    /// fsync so a crash can't lose it. Called only after the chunk's data is durably in the `.part`.
    func markComplete(_ index: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        guard index >= 0 && index < status.count else { return }
        status[index] = 1
        guard let handle else { return }
        try handle.seek(toOffset: UInt64(Self.headerLen + index))
        try handle.write(contentsOf: Data([1]))
        try handle.synchronize()
    }

    /// Total durably-complete byte count: each completed chunk contributes `chunkSize`, except the
    /// last chunk, which contributes the remainder `total - (chunkCount-1)*chunkSize`. Clamped to
    /// `total` so it never overshoots regardless of rounding.
    func completedBytes() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        var sum: Int64 = 0
        let lastIndex = chunkCount - 1
        for (i, b) in status.enumerated() where b == 1 {
            sum += (i == lastIndex) ? (total - Int64(lastIndex) * chunkSize) : chunkSize
        }
        return min(sum, total)
    }

    /// Close the handle and remove the sidecar — called once the download has fully completed (or is
    /// cancelled), so a stale bitmap never outlives its `.part`.
    func delete() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: sidecarURL)
    }

    // MARK: - Header encoding

    private static func headerBytes(total: Int64, chunkSize: Int64) -> Data {
        var data = magic
        data.append(int64LE(total))
        data.append(int64LE(chunkSize))
        return data
    }

    private static func int64LE(_ value: Int64) -> Data {
        var le = value.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }

    private static func readInt64LE(_ data: Data, at offset: Int) -> Int64 {
        // `Data` slices keep their parent's indices, so index from the slice's own start.
        let slice = data.subdata(in: offset..<(offset + 8))
        let le = slice.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
        return Int64(littleEndian: le)
    }
}
