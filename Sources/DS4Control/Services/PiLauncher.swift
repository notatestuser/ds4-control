import Foundation

/// Opens Terminal.app running the `pi` coding agent against the local ds4 server.
/// The `pi` "ds4" provider (base URL `http://127.0.0.1:8000/v1`, API key) is defined in
/// ~/.pi/agent/models.json; here we only select the running model via `--model ds4/<id>`.
enum PiLauncher {
    /// Model ids the `pi` "ds4" provider exposes (must match ~/.pi/agent/models.json).
    static let knownModelIds = ["deepseek-v4-pro", "deepseek-v4-flash"]

    /// `ds4/<id>` spec for `pi --model`. Prefers the server's reported `activeModel`
    /// when it is a known ds4 id; otherwise falls back to the selected variant's id
    /// (covers the orphan-attach case where `activeModel` is a server display name).
    static func modelSpec(for activeModel: String?, fallback: Variant) -> String {
        let id = activeModel.flatMap { knownModelIds.contains($0) ? $0 : nil } ?? fallback.modelId
        return "ds4/\(id)"
    }

    /// AppleScript that opens Terminal and runs pi. `modelSpec` comes from a fixed set,
    /// so there is no shell/AppleScript injection surface.
    static func appleScript(modelSpec: String) -> String {
        """
        tell application "Terminal"
            activate
            do script "pi --model \(modelSpec)"
        end tell
        """
    }

    /// Launch Terminal running pi for the given spec (e.g. "ds4/deepseek-v4-pro").
    /// Shells out to `osascript` (the Apple-event sender), so the app needs only the
    /// one-time "control Terminal" automation consent, no entitlement. `do script` runs
    /// a login-interactive shell, so `.zshrc` (nvm) puts `pi` on PATH.
    static func launch(modelSpec: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript(modelSpec: modelSpec)]
        try? process.run()
    }
}
