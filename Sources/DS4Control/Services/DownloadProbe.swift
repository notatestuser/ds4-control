import Foundation

/// Bytes downloaded so far for `filename` under `ggufDir`. Checked in order: the final
/// file (download complete); the parallel downloader's bitmap sidecar `<filename>.part.dl` (the
/// `.part` itself is *sparse*/preallocated, so its size is meaningless — read the bitmap instead);
/// curl's `<filename>.part` (download_model.sh streams to it and renames on completion); then any
/// in-flight `hf` `*.incomplete` files. TTY-independent and works regardless of which downloader
/// (the native parallel HFDownloader, curl, `hf`, …) produced the partial.
func downloadedBytes(ggufDir: URL, filename: String) -> Int64 {
    let finalSize = fileSize(ggufDir.appendingPathComponent(filename))
    if finalSize > 0 { return finalSize }
    // A `.part.dl` sidecar means a parallel download is in flight; its `.part` is sparse, so the
    // bitmap — not the file size — is the only correct byte count.
    if FileManager.default.fileExists(atPath: ggufDir.appendingPathComponent(filename + ".part.dl").path) {
        return resumableBytes(ggufDir: ggufDir, filename: filename)
    }
    let partSize = fileSize(ggufDir.appendingPathComponent(filename + ".part"))
    if partSize > 0 { return partSize }
    let incompleteDir = ggufDir.appendingPathComponent(".cache/huggingface/download")
    guard
        let items = try? FileManager.default.contentsOfDirectory(
            at: incompleteDir, includingPropertiesForKeys: [.fileSizeKey])
    else { return 0 }
    return items.filter { $0.pathExtension == "incomplete" }.reduce(0) { $0 + fileSize($1) }
}

/// Durably-downloaded bytes recorded in the parallel downloader's `<filename>.part.dl` bitmap
/// sidecar, or 0 if it's absent/invalid. Used to detect (and size) a resumable parallel download:
/// the `.part` is preallocated/sparse, so only the bitmap knows how much is really on disk. Mirrors
/// `ChunkBitmap.completedBytes()` by parsing the sidecar header (magic + total + chunkSize) and
/// summing each set bit's chunk size (clamping the last chunk to the remainder).
func resumableBytes(ggufDir: URL, filename: String) -> Int64 {
    let sidecar = ggufDir.appendingPathComponent(filename + ".part.dl")
    guard let data = try? Data(contentsOf: sidecar) else { return 0 }
    let magic = Data("DS4DL1\n".utf8)
    let headerLen = magic.count + 16  // magic + total(Int64) + chunkSize(Int64)
    guard data.count > headerLen, data.prefix(magic.count) == magic else { return 0 }
    let total = readInt64LE(data, at: magic.count)
    let chunkSize = readInt64LE(data, at: magic.count + 8)
    guard total > 0, chunkSize > 0 else { return 0 }
    let chunkCount = Int((total + chunkSize - 1) / chunkSize)
    guard data.count == headerLen + chunkCount else { return 0 }  // stale/truncated → not resumable.
    let status = data.suffix(chunkCount)
    let lastIndex = chunkCount - 1
    var sum: Int64 = 0
    for (i, b) in status.enumerated() where b == 1 {
        sum += (i == lastIndex) ? (total - Int64(lastIndex) * chunkSize) : chunkSize
    }
    return min(sum, total)
}

/// Read a little-endian Int64 at `offset` in `data` (the sidecar header is LE — see ChunkBitmap).
private func readInt64LE(_ data: Data, at offset: Int) -> Int64 {
    let slice = data.subdata(in: offset..<(offset + 8))
    let le = slice.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
    return Int64(littleEndian: le)
}

/// Format a bytes/second rate as a short human string (decimal units, e.g. "213 MB/s").
func formatRate(_ bytesPerSec: Double) -> String {
    let r = max(0, bytesPerSec)
    if r >= 1_000_000_000 { return String(format: "%.1f GB/s", r / 1_000_000_000) }
    if r >= 1_000_000 { return String(format: "%.0f MB/s", r / 1_000_000) }
    if r >= 1_000 { return String(format: "%.0f KB/s", r / 1_000) }
    return String(format: "%.0f B/s", r)
}

/// Resolve an optional HuggingFace token from the `HF_TOKEN` environment variable,
/// falling back to the local hf login cache. Used only for *optional* auth (the
/// repo is public) and passed to the downloader via the environment, never `--token`.
func resolveHFToken(env: [String: String], cacheFile: URL) -> String? {
    if let t = env["HF_TOKEN"], !t.isEmpty { return t }
    if let cached = try? String(contentsOf: cacheFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !cached.isEmpty
    {
        return cached
    }
    return nil
}

private func fileSize(_ url: URL) -> Int64 {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey])
    return Int64(values?.fileSize ?? 0)
}
