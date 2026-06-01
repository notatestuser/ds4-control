import Foundation

enum Paths {
    /// The ds4 runtime directory (contains ds4-server, download_model.sh, metal/, gguf/).
    /// Predetermined by the app's support location — no user setting. `DS4_DIR` overrides it
    /// for CI/advanced use. In dev, symlink the support path to your checkout so the app finds
    /// the real binaries:
    ///   ln -s <repo>/ds4 ~/Library/Application\ Support/DS4Control/ds4
    static func ds4Dir() -> URL {
        if let override = ProcessInfo.processInfo.environment["DS4_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("DS4Control/ds4")
    }
}
