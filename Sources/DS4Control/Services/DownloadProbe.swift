import Foundation

/// Bytes downloaded so far for `filename` under `ggufDir`. Checked in order: the final
/// file (download complete); curl's `<filename>.part` (download_model.sh streams to it and
/// renames on completion); then any in-flight `hf` `*.incomplete` files. TTY-independent and
/// works regardless of which downloader (curl, `hf`, …) `download_model.sh` uses.
func downloadedBytes(ggufDir: URL, filename: String) -> Int64 {
    let finalSize = fileSize(ggufDir.appendingPathComponent(filename))
    if finalSize > 0 { return finalSize }
    let partSize = fileSize(ggufDir.appendingPathComponent(filename + ".part"))
    if partSize > 0 { return partSize }
    let incompleteDir = ggufDir.appendingPathComponent(".cache/huggingface/download")
    guard
        let items = try? FileManager.default.contentsOfDirectory(
            at: incompleteDir, includingPropertiesForKeys: [.fileSizeKey])
    else { return 0 }
    return items.filter { $0.pathExtension == "incomplete" }.reduce(0) { $0 + fileSize($1) }
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
