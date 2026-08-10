import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var supervisor: SupervisorService
    private let ram = systemRamGiB()
    @State private var confirmingCleanup = false
    @State private var confirmingDSparkEnable = false
    @State private var confirmingDSparkRemove = false

    private var isRunning: Bool { supervisor.state == .ready || supervisor.state == .starting }
    /// Busy = a server is running/starting/stopping or a download is in flight; cleanup is
    /// disabled then so an in-use or downloading model is never removed.
    private var isBusy: Bool {
        switch supervisor.state {
        case .idle, .error: return false
        default: return true
        }
    }
    /// Downloaded Flash quants other than the selected one — candidates for cleanup.
    private var removableFlashQuants: [FlashQuant] {
        FlashQuant.allCases.filter { $0 != app.selectedFlashQuant && supervisor.isFlashQuantDownloaded($0) }
    }
    private var removableFreedGiB: Int {
        Int(removableFlashQuants.reduce(0.0) { $0 + $1.quant.weightsGiB })
    }
    private var flashModelFooter: String {
        let base =
            "Which Flash weights to download and run. Sizes are running memory; "
            + "options that don't fit this Mac's RAM are unavailable."
        return isBusy
            ? base + " Stop the server to delete unused downloads."
            : base + " Clean up deletes other downloaded Flash variants (V4 Pro is always kept)."
    }

    private var ctxHint: String {
        if app.ctxOverride > 0 {
            return "Max Think is available when context ≥ 393,216."
        }
        return
            "Auto: \(defaultCtx(ramGiB: ram, variant: app.selectedVariant, flashQuant: app.selectedFlashQuant).formatted()) tokens (based on \(Int(ram)) GiB RAM)."
    }

    private var restartHint: String {
        isRunning
            ? "Restarts ds4-server with these settings."
            : "Server not running — settings apply on next Start."
    }
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) })
    }

    // MARK: - DSpark

    /// Turning DSpark ON routes through a confirmation first — it starts a ~5.6 GiB download and
    /// makes chat replies deterministic, neither of which should happen from a silent tap. Turning
    /// it OFF is immediate and never deletes the downloaded file.
    private var dsparkBinding: Binding<Bool> {
        Binding(
            get: { app.dsparkSpeculation },
            set: { on in
                if on {
                    confirmingDSparkEnable = true
                } else {
                    app.dsparkSpeculation = false
                }
            })
    }
    /// Why an enabled DSpark won't reach ds4-server with the current settings, or nil when it will.
    /// Mirrors `dsparkApplies` — both gates come from ds4's own decode path.
    private var dsparkSkipReason: String? {
        guard app.dsparkSpeculation else { return nil }
        if app.selectedVariant != .flash {
            return "DSpark supports V4 Flash only — it will be skipped while V4 Pro is selected."
        }
        if app.concurrentSessions > 1 {
            return
                "Concurrent sessions above 1 turns on batched mode, which disables speculative "
                + "decoding — DSpark will be skipped."
        }
        return nil
    }
    private var dsparkSizeLabel: String { String(format: "%.1f GiB", DSparkSupport.giB) }
    /// Explains the trade both ways: greedy is what lets DSpark help the chat, but it is below
    /// DeepSeek's recommended sampling, so it stays the user's explicit choice.
    private var greedyChatFooter: String {
        let base =
            "Greedy replies send temperature 0, so the same prompt always gives the same answer. "
            + "DeepSeek recommends 1.0 for V4, so leave this off unless you want determinism — "
            + "or unless you want DSpark below to speed up the chat, which only works at temperature 0."
        return app.dsparkSpeculation && !app.greedyChat
            ? base + " DSpark is on but the chat is still sampling, so DSpark will not speed it up."
            : base
    }
    /// Spelled out at the moment the user flips the toggle on: what gets downloaded, and that chat
    /// replies become deterministic. Built here rather than inline so the type checker doesn't have
    /// to solve a long concatenation inside the view builder.
    private var dsparkEnableMessage: String {
        let already = supervisor.isDSparkSupportDownloaded() ? " (already downloaded)." : "."
        let size = "Downloads a \(dsparkSizeLabel) support model for V4 Flash" + already
        let applies =
            "\n\nds4 only uses DSpark for requests sent at temperature 0. Coding agents choose "
            + "their own; for the built-in chat, turn on \"Greedy replies\" under Chat. "
            + "It takes effect the next time the server starts."
        return size + applies
    }

    private var powerBinding: Binding<Double> {
        Binding(get: { Double(app.power ?? 100) }, set: { app.power = Int($0.rounded()) })
    }
    private var sessionsBinding: Binding<Double> {
        Binding(get: { Double(app.concurrentSessions) }, set: { app.concurrentSessions = Int($0.rounded()) })
    }
    /// Context-size field as text. Always shows the active window: the override if set, else the
    /// tiered default — so the box is never blank. Backspacing it away stores 0 (auto), which the
    /// getter immediately re-renders as the default value.
    private var ctxText: Binding<String> {
        Binding(
            get: {
                let active =
                    app.ctxOverride > 0
                    ? app.ctxOverride
                    : defaultCtx(ramGiB: ram, variant: app.selectedVariant, flashQuant: app.selectedFlashQuant)
                return String(active)
            },
            set: { app.ctxOverride = Int($0.filter(\.isNumber)) ?? 0 })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Open DS4 Control at login", isOn: launchAtLoginBinding)
                if let err = app.launchAtLoginError {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("Launches the menu bar app automatically when you sign in to your Mac.")
            }

            Section {
                LabeledContent {
                    TextField("Auto", text: ctxText)
                        .labelsHidden().multilineTextAlignment(.trailing).frame(width: 130)
                } label: {
                    Text("Context size")
                }
                LabeledContent {
                    TextField("", value: $app.port, format: .number.grouping(.never))
                        .labelsHidden().multilineTextAlignment(.trailing).frame(width: 130)
                } label: {
                    Text("Port")
                }
                LabeledContent {
                    TextField("", text: $app.host)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                } label: {
                    Text("Bind host")
                }
                Text(
                    "The address ds4-server listens on. "
                        + "Chat and agents on this Mac always use 127.0.0.1. "
                        + "Enter 0.0.0.0 to let other devices connect."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: sessionsBinding, in: 1...16, step: 1)
                        Text("\(app.concurrentSessions)")
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                    .frame(width: 230)
                } label: {
                    Text("Concurrent sessions")
                }
                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: powerBinding, in: 1...100)
                        Text("\(app.power ?? 100)")
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                    .frame(width: 230)
                } label: {
                    Text("GPU power duty")
                }
                Toggle("Disk KV cache", isOn: $app.kvDiskCache)
            } header: {
                Text("Server")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ctxHint)
                    Text(
                        "Concurrent sessions run that many chats or coding agents at the same time. "
                            + "Memory use grows with sessions × context size. "
                            + "Applies on next server start or restart.")
                    Text(
                        "Disk KV cache keeps the prompt cache on disk so repeated prompts start "
                            + "faster. Applies on next server start or restart.")
                }
            }

            Section {
                Button("Apply & Restart Server", action: restart)
                    .disabled(!isRunning)
            } footer: {
                Text(restartHint)
            }

            Section {
                ThinkingModePicker()
                Toggle("Greedy replies", isOn: $app.greedyChat)
            } header: {
                Text("Chat")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        "Max Think needs a context of at least 393,216 — you'll be asked to raise it. "
                            + "Coding agents set their own level; this only affects the built-in chat.")
                    Text(greedyChatFooter)
                }
            }

            Section {
                Picker("Variant", selection: $app.selectedFlashQuant) {
                    ForEach(FlashQuant.allCases) { q in
                        Text(q.label + (supervisor.isFlashQuantDownloaded(q) ? "  (downloaded)" : ""))
                            .tag(q)
                            .disabled(!flashQuantFits(q, ramGiB: ram))
                    }
                }
                .disabled(supervisor.state == .downloading)  // locked while a download is in progress
                Button("Clean up unused Flash downloads") { confirmingCleanup = true }
                    .disabled(removableFlashQuants.isEmpty || isBusy)
            } header: {
                Text("V4 Flash model")
            } footer: {
                Text(flashModelFooter)
            }
            .confirmationDialog(
                "Delete other V4 Flash downloads?", isPresented: $confirmingCleanup,
                titleVisibility: .visible
            ) {
                Button(
                    "Delete \(removableFlashQuants.count) file(s) · ~\(removableFreedGiB) GiB",
                    role: .destructive
                ) {
                    supervisor.cleanupUnusedFlashQuants(keep: app.selectedFlashQuant)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Keeps the selected variant and V4 Pro. Deleted weights must be downloaded again.")
            }

            dsparkSection

            Section {
                Toggle("High performance mode", isOn: $app.highPerformanceDownload)
            } header: {
                Text("Downloads")
            } footer: {
                Text(
                    "Downloads use 64 connections instead of 8. Leave off behind CGNAT or strict NAT — "
                        + "it can overload your router and knock you offline."
                )
            }

        }
        .formStyle(.grouped)
        .frame(width: 480, height: 600)
        .onAppear {
            app.refreshLaunchAtLoginStatus()  // pick up any change made in System Settings
            WindowChrome.windowOpened(title: "DS4 Control Settings")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // After approving the login item in System Settings the OS state can change while
            // we're backgrounded; re-sync the snapshot when the app becomes active again.
            app.refreshLaunchAtLoginStatus()
        }
        .onDisappear { WindowChrome.windowClosed() }
    }

    // MARK: - DSpark section

    @ViewBuilder private var dsparkSection: some View {
        Section {
            Toggle("DSpark speculative decoding", isOn: dsparkBinding)
            dsparkStatusRow
            if let reason = dsparkSkipReason {
                Text(reason)
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Speculative decoding")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "DSpark is DeepSeek's draft model for V4 Flash: it proposes several tokens ahead "
                        + "and Flash verifies them, so generation can advance faster. Downloading it once "
                        + "takes about \(dsparkSizeLabel). Experimental — predictable text like code gains "
                        + "the most, and some prompts see no speedup at all.")
                Text(
                    "ds4 only applies it to requests sent at temperature 0 — its speculative path is "
                        + "greedy-only. The built-in chat qualifies only with \"Greedy replies\" on; "
                        + "coding agents send their own temperature.")
                Text("Applies on next server start or restart.")
            }
        }
        .confirmationDialog(
            "Enable DSpark speculative decoding?", isPresented: $confirmingDSparkEnable,
            titleVisibility: .visible
        ) {
            Button("Download & Enable") {
                app.dsparkSpeculation = true
                supervisor.downloadDSparkSupport(highPerformance: app.highPerformanceDownload)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(dsparkEnableMessage)
        }
        .confirmationDialog(
            "Delete the DSpark support model?", isPresented: $confirmingDSparkRemove,
            titleVisibility: .visible
        ) {
            Button("Delete · \(dsparkSizeLabel)", role: .destructive) { supervisor.removeDSparkSupport() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Turning DSpark back on will download it again.")
        }
    }

    /// One row under the toggle, showing whichever of the four states applies: downloading (bar +
    /// Cancel), parked behind a model download, failed (+ Retry), or on disk (+ Remove).
    @ViewBuilder private var dsparkStatusRow: some View {
        if let d = supervisor.supportDownload {
            ProgressView(value: d.pct, total: 100) {
                HStack(spacing: 6) {
                    if supervisor.supportDownloadLive {
                        ProgressView().progressViewStyle(.circular).controlSize(.small)
                    }
                    Text(d.file).font(.caption2).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Cancel", role: .destructive) { supervisor.cancelDSparkSupportDownload() }
                        .font(.caption2)
                }
            } currentValueLabel: {
                Text(supportDownloadLabel(d)).font(.caption2)
            }
        } else if supervisor.supportDownloadDeferred {
            Text("Waiting for the model download to finish…")
                .font(.caption2).foregroundStyle(.secondary)
        } else if let err = supervisor.supportDownloadError {
            HStack(spacing: 8) {
                Text("Download failed (\(err)).")
                    .font(.caption2).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") { supervisor.downloadDSparkSupport(highPerformance: app.highPerformanceDownload) }
                    .font(.caption2)
            }
        } else if supervisor.isDSparkSupportDownloaded() {
            HStack(spacing: 8) {
                Text("Downloaded · \(dsparkSizeLabel)").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                // Only offered while DSpark is off and nothing is running — same gating as the
                // Flash cleanup, so a mapped or in-use support model is never deleted.
                if !app.dsparkSpeculation && !isBusy {
                    Button("Remove download") { confirmingDSparkRemove = true }
                        .font(.caption2)
                }
            }
        }
    }

    /// "58% · 3.2/6.0 GB · 190 MB/s". One decimal, unlike the popup's whole-GB model bar — at
    /// ~6 GB the coarse format would read "3/6 GB" and look stuck.
    private func supportDownloadLabel(_ d: DownloadProgress) -> String {
        var parts = [String(format: "%.0f%%", d.pct)]
        if let total = d.totalBytes, total > 0 {
            parts.append(
                String(format: "%.1f/%.1f GB", Double(d.receivedBytes) / 1e9, Double(total) / 1e9))
        }
        if let rate = d.rate { parts.append(rate) }
        return parts.joined(separator: " · ")
    }

    private func restart() {
        let host = app.normalizeHostForLaunch()
        supervisor.restart(
            variant: app.selectedVariant, flashQuant: app.selectedFlashQuant,
            ctx: app.effectiveCtx(ramGiB: ram),
            host: host, port: app.port, power: app.power,
            sessions: app.concurrentSessions,
            kvDiskDir: app.kvDiskCache ? supervisor.kvDiskCacheURL : nil,
            dsparkSupport: supervisor.dsparkSupportArg(
                enabled: app.dsparkSpeculation, variant: app.selectedVariant,
                sessions: app.concurrentSessions))
    }
}
