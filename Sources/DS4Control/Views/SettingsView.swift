import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var supervisor: SupervisorService
    private let ram = systemRamGiB()
    @State private var confirmingCleanup = false
    @State private var confirming41Cleanup = false

    private var isRunning: Bool { supervisor.state == .ready || supervisor.state == .starting }
    /// Busy = a server is running/starting/stopping or a download is in flight; cleanup is
    /// disabled then so an in-use or downloading model is never removed.
    private var isBusy: Bool {
        switch supervisor.state {
        case .idle, .error: return false
        default: return true
        }
    }
    /// Flash quants with any removable on-disk artifact — a final GGUF, or stranded partial
    /// artifacts (`.part` + `.part.dl` from a failed or interrupted download) with no final.
    private var flashCleanupQuants: [FlashQuant] {
        FlashQuant.allCases.filter {
            supervisor.isFlashQuantDownloaded($0) || supervisor.hasFlashPartialDownload($0)
        }
    }
    /// Cleanup candidates excluding the selected quant — "Delete other downloads".
    private var removableFlashCleanupQuants: [FlashQuant] {
        flashCleanupQuants.filter { $0 != app.selectedFlashQuant }
    }
    private func flashCleanupFiles(_ quants: [FlashQuant]) -> Int {
        quants.reduce(0) { $0 + supervisor.flashArtifactURLs($1).count }
    }
    private func flashCleanupGiB(_ quants: [FlashQuant]) -> Int {
        Int((quants.reduce(0.0) { $0 + Double(supervisor.flashArtifactBytes($1)) }) / 1_073_741_824)
    }
    /// V4.1 quants with any removable on-disk artifact — a verified final, an unverified
    /// final, or stranded partials (`.part`/`.part.dl`, an interrupted join's `.assembling`).
    private var flash41CleanupQuants: [Flash41Quant] {
        Flash41Quant.allCases.filter {
            supervisor.isFlash41QuantDownloaded($0) || supervisor.hasFlash41PartialDownload($0)
        }
    }
    /// Cleanup candidates excluding the selected quant — "Delete the other V4.1 quant".
    private var removableFlash41CleanupQuants: [Flash41Quant] {
        flash41CleanupQuants.filter { $0 != app.selectedFlash41Quant }
    }
    private func flash41CleanupFiles(_ quants: [Flash41Quant]) -> Int {
        quants.reduce(0) { $0 + supervisor.flash41ArtifactURLs($1).count }
    }
    private func flash41CleanupGiB(_ quants: [Flash41Quant]) -> Int {
        Int((quants.reduce(0.0) { $0 + Double(supervisor.flash41ArtifactBytes($1)) }) / 1_073_741_824)
    }
    private var flashModelFooter: String {
        let base =
            "Which Flash weights to download and run. Sizes are running memory; "
            + "options that don't fit this Mac's RAM are unavailable."
        return isBusy
            ? base + " Stop the server to delete unused downloads."
            : base
                + " Clean up can delete the other downloaded Flash variants or all of them "
                + "(V4 Pro is always kept)."
    }
    private var flash41ModelFooter: String {
        let base =
            "Which V4.1 weights to download and run. Labels show resident main weights; "
            + "~189 GiB of Engram tables stream from the SSD in every mode. Full GPU power is "
            + "always used, and SSD streaming engages automatically when full residency doesn't fit."
        return isBusy
            ? base + " Stop the server to delete unused downloads."
            : base + " Clean up deletes the other downloaded V4.1 quant (V4 Pro is always kept)."
    }

    private var ctxHint: String {
        if app.ctxOverride > 0 {
            if app.selectedVariant == .flash41 {
                return "V4.1 Flash runs Max Think at any context; no minimum applies."
            }
            if !supportsMaxThink(ramGiB: ram) {
                return "Max Think is unavailable below 128 GiB unified memory."
            }
            return "Max Think is available when context ≥ 393,216."
        }
        return
            "Auto: \(defaultCtx(ramGiB: ram, selection: app.quantSelection).formatted()) tokens (based on \(Int(ram)) GiB RAM)."
    }

    private var thinkingHint: String {
        if app.selectedVariant == .flash41 {
            return
                "Coding agents set their own level; this only affects the built-in chat. "
                + "V4.1 Flash has no Max Think context floor."
        }
        if !supportsMaxThink(ramGiB: ram) {
            return
                "Max Think requires at least 128 GiB unified memory. "
                + "Coding agents set their own level; this only affects the built-in chat."
        }
        return
            "Max Think needs a context of at least 393,216 — you'll be asked to raise it. "
            + "Coding agents set their own level; this only affects the built-in chat."
    }

    private var restartHint: String {
        isRunning
            ? "Restarts ds4-server with these settings."
            : "Server not running — settings apply on next Start."
    }
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) })
    }
    private var stopServerOnQuitBinding: Binding<Bool> {
        Binding(get: { app.stopServerOnQuit }, set: { app.setStopServerOnQuit($0) })
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
                String(app.effectiveCtx(ramGiB: ram))
            },
            set: {
                let digits = $0.filter(\.isNumber)
                guard !digits.isEmpty else { app.ctxOverride = 0; return }
                app.ctxOverride = min(Int(digits) ?? app.selectedVariant.ctxCeiling, app.selectedVariant.ctxCeiling)
            })
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
                Toggle("Stop ds4-server when DS4 Control quits", isOn: stopServerOnQuitBinding)
            } header: {
                Text("App")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Launches the menu bar app automatically when you sign in to your Mac.")
                    Text(
                        "When off, quitting DS4 Control leaves ds4-server and its loaded model "
                            + "available in the background."
                    )
                }
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
                        Slider(value: sessionsBinding, in: 1...Double(maxConcurrentSessions), step: 1)
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
                        "Disk KV cache checkpoints session state so conversations can resume faster "
                            + "after slot reuse or restart. It does not reduce resident memory. "
                            + "Applies on next server start or restart.")
                }
            }

            Section {
                Button("Apply & Restart Server") { restart() }
                    .disabled(!isRunning)
            } footer: {
                Text(restartHint)
            }

            Section {
                ThinkingModePicker()
            } header: {
                Text("Chat")
            } footer: {
                Text(thinkingHint)
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
                Button("Clean up Flash downloads…") { confirmingCleanup = true }
                    .disabled(flashCleanupQuants.isEmpty || isBusy)
            } header: {
                Text("V4 Flash (0731) model")
            } footer: {
                Text(flashModelFooter)
            }
            .confirmationDialog(
                "Delete V4 Flash downloads?", isPresented: $confirmingCleanup,
                titleVisibility: .visible
            ) {
                if !removableFlashCleanupQuants.isEmpty {
                    Button(
                        "Delete other downloads · \(flashCleanupFiles(removableFlashCleanupQuants)) file(s), ~\(flashCleanupGiB(removableFlashCleanupQuants)) GiB",
                        role: .destructive
                    ) {
                        supervisor.cleanupUnusedFlashQuants(keep: app.selectedFlashQuant)
                    }
                }
                Button(
                    "Delete all downloads · \(flashCleanupFiles(flashCleanupQuants)) file(s), ~\(flashCleanupGiB(flashCleanupQuants)) GiB",
                    role: .destructive
                ) {
                    supervisor.cleanupAllFlashQuants()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("V4 Pro is always kept. Deleted weights must be downloaded again.")
            }

            Section {
                Picker("Quant", selection: $app.selectedFlash41Quant) {
                    ForEach(Flash41Quant.allCases) { q in
                        Text(q.label + (supervisor.isFlash41QuantDownloaded(q) ? "  (downloaded)" : ""))
                            .tag(q)
                            .disabled(
                                !flash41QuantFits(
                                    q, ramGiB: ram, wiredLimitMB: effectiveWiredLimitMB(ramGiB: ram)))
                    }
                }
                .disabled(supervisor.state == .downloading)  // locked while a download is in progress
                Button("Clean up V4.1 downloads…") { confirming41Cleanup = true }
                    .disabled(flash41CleanupQuants.isEmpty || isBusy)
            } header: {
                Text("V4.1 Flash model")
            } footer: {
                Text(flash41ModelFooter)
            }
            .confirmationDialog(
                "Delete the other V4.1 Flash quant?", isPresented: $confirming41Cleanup,
                titleVisibility: .visible
            ) {
                if !removableFlash41CleanupQuants.isEmpty {
                    Button(
                        "Delete other downloads · \(flash41CleanupFiles(removableFlash41CleanupQuants)) file(s), ~\(flash41CleanupGiB(removableFlash41CleanupQuants)) GiB",
                        role: .destructive
                    ) {
                        supervisor.cleanupUnusedFlash41Quants(keep: app.selectedFlash41Quant)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Keeps the selected quant and V4 Pro. Deleted weights must be downloaded again.")
            }

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

    private func restart(overrideWiredLimitGate: Bool = false) {
        let host = app.normalizeHostForLaunch()
        let result = supervisor.restart(
            selection: app.quantSelection,
            ctx: app.effectiveCtx(ramGiB: ram),
            host: host, port: app.port, power: app.power,
            sessions: app.concurrentSessions,
            kvDiskDir: app.kvDiskCache ? supervisor.kvDiskCacheURL(for: app.selectedVariant) : nil,
            overrideWiredLimitGate: overrideWiredLimitGate)
        if case let .rejected(feasibility) = result {
            RestartRejectionAlert.show(
                feasibility,
                contextSentence: "The current server is still running."
            ) {
                restart(overrideWiredLimitGate: true)
            }
        }
    }
}
