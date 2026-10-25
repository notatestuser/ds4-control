import Foundation

/// Exact, generation-scoped cleanup for the pre-1017 V4.1 weights. Discovery is read-only;
/// removal accepts only the paths shown in the native confirmation alert. No shared HF
/// cache glob or current-generation file is eligible.
enum Flash41LegacyStorage {
    struct CleanupError: LocalizedError {
        let failures: [String]
        let removed: [URL]

        var errorDescription: String? {
            "Some old V4.1 data could not be deleted. You can retry in Settings.\n"
                + failures.joined(separator: "\n")
        }
    }

    private static let hfDirectory = ".cache/huggingface/download"
    private static let oldCacheName = "kv-flash-41"
    private static let sidecarSuffixes = [
        "", ".verified", ".part", ".part.dl", ".assembling", ".assembling.json",
    ]

    static func candidates(ggufDirectory: URL, cacheDirectory: URL) -> [URL] {
        let fm = FileManager.default
        var paths = artifactNames.map { ggufDirectory.appendingPathComponent($0) }
        let hf = ggufDirectory.appendingPathComponent(hfDirectory, isDirectory: true)
        // Do not enumerate a symlinked HF cache directory (or any symlinked ancestor).
        if hasSafeParent(hf.appendingPathComponent("placeholder"), root: ggufDirectory),
            let items = try? fm.contentsOfDirectory(at: hf, includingPropertiesForKeys: nil)
        {
            // FileManager may canonicalize /var to /private/var for enumerated children.
            // Keep the explicitly configured root spelling so eligibility and confirmation
            // use the same paths without resolving a candidate's own symlink.
            paths += items.filter { isAssociatedHFArtifact($0.lastPathComponent) }
                .map { hf.appendingPathComponent($0.lastPathComponent) }
        }
        paths.append(cacheDirectory.appendingPathComponent(oldCacheName, isDirectory: true))
        return paths.filter { attributes($0) != nil }.sorted { $0.path < $1.path }
    }

    /// Allocated bytes where available, so a sparse native-download partial does not claim
    /// its entire preallocated logical size as reclaimable disk space. Symlinks are never
    /// traversed while estimating the cache directory.
    static func totalBytes(for urls: [URL]) -> Int64 {
        urls.reduce(0) { total, url in
            let (next, overflow) = total.addingReportingOverflow(allocatedBytes(url))
            return overflow ? Int64.max : next
        }
    }

    /// The supervisor rechecks the process/state gate immediately before calling this.
    /// Revalidate each confirmed path and its parent chain before removal; partial failures
    /// are collected rather than hiding a failed path or preventing the rest from finishing.
    static func remove(
        candidates confirmedURLs: [URL], ggufDirectory: URL, cacheDirectory: URL,
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws {
        var failures: [String] = []
        var removed: [URL] = []
        var seen = Set<String>()
        for candidate in confirmedURLs {
            let url = candidate.standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            guard isEligible(url, ggufDirectory: ggufDirectory, cacheDirectory: cacheDirectory) else {
                failures.append("\(url.path): this path is outside the old V4.1 storage list.")
                continue
            }
            guard let values = attributes(url) else { continue }  // removed since confirmation
            let root = url.lastPathComponent == oldCacheName ? cacheDirectory : ggufDirectory
            guard hasSafeParent(url, root: root), values[.type] as? FileAttributeType != .typeSymbolicLink else {
                failures.append("\(url.path): a symbolic link prevents safe cleanup.")
                continue
            }
            if values[.type] as? FileAttributeType == .typeDirectory,
                url.lastPathComponent != oldCacheName
            {
                failures.append("\(url.path): expected an old download file, found a directory.")
                continue
            }
            do {
                try removeItem(url)
                removed.append(url)
            } catch {
                failures.append("\(url.path): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { throw CleanupError(failures: failures, removed: removed) }
    }

    private static var artifactNames: Set<String> {
        Set(
            Quant.legacyFlash41Filenames.flatMap { name in
                sidecarSuffixes.flatMap { suffix in [name + suffix, name + suffix + ".lock"] }
            })
    }

    private static func isAssociatedHFArtifact(_ name: String) -> Bool {
        Quant.legacyFlash41Filenames.contains { filename in
            if name == filename + ".metadata" || name == filename + ".lock"
                || name == filename + ".incomplete"
            {
                return true
            }
            // HF local-dir downloads name resumable blobs `<filename>.<etag>.incomplete`.
            // Bind the complete old filename and require a hash-shaped ETag; an unrelated
            // .incomplete file is never selected merely because it shares this directory.
            let prefix = filename + "."
            let suffix = ".incomplete"
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
            let digest = name.dropFirst(prefix.count).dropLast(suffix.count)
            return (digest.count == 40 || digest.count == 64)
                && digest.allSatisfy { $0.isASCII && $0.isHexDigit }
        }
    }

    private static func isEligible(_ url: URL, ggufDirectory: URL, cacheDirectory: URL) -> Bool {
        let gguf = ggufDirectory.standardizedFileURL
        let cache = cacheDirectory.standardizedFileURL
        if url.path == cache.appendingPathComponent(oldCacheName).path { return true }
        if url.deletingLastPathComponent().path == gguf.path { return artifactNames.contains(url.lastPathComponent) }
        let hf = gguf.appendingPathComponent(hfDirectory).standardizedFileURL
        return url.deletingLastPathComponent().path == hf.path && isAssociatedHFArtifact(url.lastPathComponent)
    }

    /// The explicitly configured root may itself live on another disk. All descendants
    /// between that root and a candidate must be real directories, never links elsewhere.
    private static func hasSafeParent(_ url: URL, root: URL) -> Bool {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard parent.path == rootPath || parent.path.hasPrefix(rootPath + "/") else { return false }
        let relative = String(parent.path.dropFirst(rootPath.count))
        let expectedParent = URL(fileURLWithPath: canonicalRoot.path + relative).standardizedFileURL
        return parent.resolvingSymlinksInPath().path == expectedParent.path
    }

    private static func attributes(_ url: URL) -> [FileAttributeKey: Any]? {
        // attributesOfItem uses lstat semantics: a dangling symbolic link is still visible
        // and will produce a retryable refusal instead of following it during cleanup.
        try? FileManager.default.attributesOfItem(atPath: url.path)
    }

    private static func allocatedBytes(_ url: URL) -> Int64 {
        guard let attrs = attributes(url), let type = attrs[.type] as? FileAttributeType,
            type != .typeSymbolicLink
        else { return 0 }
        if type == .typeDirectory {
            guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            else {
                return 0
            }
            return totalBytes(for: items)
        }
        guard type == .typeRegular else { return 0 }
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? values?.fileSize ?? 0)
    }
}
