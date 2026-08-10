import Foundation

/// DSpark is DeepSeek's auxiliary draft model for V4 Flash: it reads hidden states from the main
/// model and proposes up to five future tokens, which Flash then verifies — committing only the
/// accepted prefix. Shipped as a separate ~5.6 GiB "support GGUF" (not a standalone model), passed
/// to ds4-server as `--mtp <file> --dspark`.
enum DSparkSupport {
    /// Exact GGUF filename in `antirez/deepseek-v4-gguf`. The `-0731` build matches the Flash
    /// weights this app runs (see `Quant.ggufFilename`); an identical-size unsuffixed copy also
    /// exists upstream.
    static let ggufFilename = "DeepSeek-V4-Flash-DSpark-support-0731.gguf"
    /// Exact size on the Hub — used as the progress bar's total so the bar is accurate from the
    /// first byte instead of waiting for the downloader's own HEAD probe.
    static let bytes: Int64 = 5_989_114_272
    /// Resident weights, GiB (~5.58) — for the Settings size labels.
    static var giB: Double { Double(bytes) / 1_073_741_824 }
}

/// Whether ds4-server will actually engage DSpark for this configuration. The engine's gates, in
/// one place:
///
/// - **V4 Flash only.** The support model is Flash-shaped; ds4's README states V4 PRO is
///   unsupported, and a mismatched `--mtp` file fails engine open outright.
/// - **Single session.** `--batched-session` (which we pass when Concurrent sessions > 1) disables
///   speculative decoding: ds4-server's decode loop gates on `!s->batched_mode` and logs
///   "MTP speculative decoding is disabled while native session batching is active".
///
/// The remaining engine gate — a request temperature of 0 — is a per-request property, handled by
/// the chat switching to greedy decoding while `SupervisorService.dsparkActive`.
func dsparkApplies(enabled: Bool, variant: Variant, sessions: Int) -> Bool {
    enabled && variant == .flash && sessions <= 1
}
