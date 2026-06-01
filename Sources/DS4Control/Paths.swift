import Foundation

/// Writable per-app support directory (`~/Library/Application Support/DS4 Control`),
/// created on demand. Holds the downloaded model (gguf) and the disk KV cache: the app
/// bundle's Resources are read-only and code-signed, so multi-hundred-GB model data
/// cannot live there.
func ds4AppSupportDir() -> URL {
    let base =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    let dir = base.appendingPathComponent("DS4 Control", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// The bundled ds4 directory (`ds4-server` + `download_model.sh` + `metal/` shaders),
/// resolved automatically. `DS4_DIR` overrides it for development against a live checkout.
func bundledDS4Dir() -> URL {
    if let override = ProcessInfo.processInfo.environment["DS4_DIR"], !override.isEmpty {
        return URL(fileURLWithPath: override)
    }
    let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
    return resources.appendingPathComponent("ds4", isDirectory: true)
}
