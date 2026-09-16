import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var supervisor: SupervisorService
    private let ram = systemRamGiB()
    @State private var confirmingCleanup = false
    @State private var confirming41Cleanup = false
    /// Measured form height, used to size the window like the Metal wired-limit help pane —
    /// as tall as the form needs, but capped (with the screen) so the pane opens as a
    /// comfortable settings window rather than a full-height sheet; the ScrollView scrolls.
    @State private var contentHeight: CGFloat = 0

    private var windowHeight: CGFloat {
        let cap = min((NSScreen.main?.visibleFrame.height ?? 1200) - 24, 820)
        return min(max(contentHeight, 480), cap)
    }

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
    private var cleanupFooter: String {
        let base =
            "Clean up can delete the other downloaded Flash variants or all of them, "
            + "or the other V4.1 Flash quant (V4 Pro is always kept). "
            + "Deleted weights must be downloaded again."
        return isBusy ? base + " Stop the server to delete unused downloads." : base
    }

    private var thinkingHint: String {
        let base = "Coding agents set their own level; this only affects the built-in chat."
        if app.selectedVariant == .flash41 { return base }
        if !supportsMaxThink(ramGiB: ram) {
            return "Max Think requires at least 128 GiB unified memory. " + base
        }
        return "Max Think needs a context of at least 393,216 — you'll be asked to raise it. " + base
    }

    /// The Server-group values a launch would use right now, normalized exactly the way
    /// `SupervisorService.start` normalizes them (trimmed/defaulted bind host; V4.1 ignores
    /// the power slider).
    private var configuredLaunch: LaunchConfig {
        LaunchConfig(
            selection: app.quantSelection,
            ctx: app.effectiveCtx(ramGiB: ram),
            host: SupervisorService.normalizedBindHost(app.host),
            port: app.port,
            power: app.power,
            sessions: app.concurrentSessions,
            kvDiskCache: app.kvDiskCache)
    }
    /// True when the running server's launch config differs from the live controls. An
    /// adopted server's flags are unknown (`activeConfig == nil`), so Apply stays available.
    private var hasUnappliedChanges: Bool {
        guard let active = supervisor.activeConfig else { return true }
        return active != configuredLaunch
    }
    /// "Apply & Restart Server" is only actionable while a server runs with changed settings.
    /// Clicking it restarts into the new config, and Start in the popup records one too, so
    /// the button returns to disabled either way.
    private var canApplyChanges: Bool { isRunning && hasUnappliedChanges }

    private var restartHint: String {
        guard isRunning else {
            return "Server not running — settings and variant changes apply on next Start."
        }
        return hasUnappliedChanges
            ? "Restarts ds4-server with these settings, applying any variant change."
            : "No unapplied changes."
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
    /// Largest parallel-slot count whose launch config clears the wired-limit gate at the
    /// live context without the "Start anyway" override. Always ≥ 1.
    private var fittingSessionCount: Int {
        maxFittingSessions(
            ramGiB: ram, selection: app.quantSelection,
            ctx: app.effectiveCtx(ramGiB: ram), wiredLimitMB: effectiveWiredLimitMB(ramGiB: ram))
    }
    /// Stepper bound: the fitting count, never below an already-stored value — a config that
    /// stopped fitting (raised context, heavier model tier) stays visible and reversible.
    private var stepperMaxSessions: Int { max(fittingSessionCount, app.concurrentSessions) }
    /// GPU-wired MB for `sessions` resident sessions at the live context and selection.
    private func wiredMB(sessions: Int) -> Int {
        requiredWiredMB(
            ramGiB: ram, wiredLimitMB: effectiveWiredLimitMB(ramGiB: ram),
            selection: app.quantSelection, ctx: app.effectiveCtx(ramGiB: ram), sessions: sessions)
    }
    /// What the second resident slot adds (KV + per-session Metal allocations), in whole GiB;
    /// nil when the config overflows any Mac's budget or the cost rounds below a GiB.
    private var perSlotGiB: Int? {
        let one = wiredMB(sessions: 1)
        let two = wiredMB(sessions: 2)
        guard one != Int.max, two != Int.max, two > one else { return nil }
        let gib = Int((Double(two - one) / 1024).rounded())
        return gib >= 1 ? gib : nil
    }
    /// What the current slot count adds over a single session, in whole GiB.
    private var extraGiBAtCurrentSessions: Int? {
        guard app.concurrentSessions > 1 else { return nil }
        let one = wiredMB(sessions: 1)
        let many = wiredMB(sessions: app.concurrentSessions)
        guard one != Int.max, many != Int.max, many > one else { return nil }
        let gib = Int((Double(many - one) / 1024).rounded())
        return gib >= 1 ? gib : nil
    }
    /// Live cost line under the stepper: per-slot memory at the current context, the extra
    /// for the selected count, and how many slots fit this Mac's wired limit.
    private var sessionsMemoryCaption: String {
        var parts: [String] = []
        if let perSlot = perSlotGiB {
            parts.append("≈ \(perSlot) GiB per slot at \(app.effectiveCtx(ramGiB: ram).formatted()) ctx")
        }
        if let extra = extraGiBAtCurrentSessions {
            parts.append("\(app.concurrentSessions) slots add ≈ \(extra) GiB")
        }
        parts.append("up to \(fittingSessionCount) fit this Mac")
        if app.concurrentSessions > fittingSessionCount {
            parts.append("the current \(app.concurrentSessions) doesn't fit")
        }
        return parts.joined(separator: " · ")
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
        ScrollView { form }
            .frame(width: 600, height: windowHeight)
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

    /// The settings form, sized and measured like the Metal wired-limit help pane: the
    /// ScrollView gives it an unbounded height proposal so its full natural height can be
    /// measured and shown at once, and it takes over scrolling when `windowHeight` clamps
    /// against the screen.
    @ViewBuilder private var form: some View {
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
                        Text("\(app.concurrentSessions)")
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                        Stepper(
                            "", value: sessionsBinding, in: 1...Double(stepperMaxSessions),
                            step: 1
                        )
                        .labelsHidden()
                    }
                } label: {
                    Text("Parallel chats & agents")
                }
                Text(sessionsMemoryCaption)
                    .font(.caption2)
                    .foregroundStyle(app.concurrentSessions > fittingSessionCount ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                Picker("V4 Flash variant", selection: $app.selectedFlashQuant) {
                    ForEach(FlashQuant.allCases) { q in
                        Text(q.label + (supervisor.isFlashQuantDownloaded(q) ? "  (downloaded)" : ""))
                            .tag(q)
                            .disabled(!flashQuantFits(q, ramGiB: ram))
                    }
                }
                .disabled(supervisor.state == .downloading)  // locked while a download is in progress
                Picker("V4.1 Flash variant", selection: $app.selectedFlash41Quant) {
                    ForEach(Flash41Quant.allCases) { q in
                        Text(q.label + (supervisor.isFlash41QuantDownloaded(q) ? "  (downloaded)" : ""))
                            .tag(q)
                            .disabled(
                                !flash41QuantFits(
                                    q, ramGiB: ram, wiredLimitMB: effectiveWiredLimitMB(ramGiB: ram)))
                    }
                }
                .disabled(supervisor.state == .downloading)  // locked while a download is in progress
            } header: {
                Text("Server")
            }

            Section {
                Button("Apply & Restart Server") { restart() }
                    .disabled(!canApplyChanges)
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
                Toggle("High performance mode", isOn: $app.highPerformanceDownload)
                Button("Clean up V4 Flash downloads…") { confirmingCleanup = true }
                    .disabled(flashCleanupQuants.isEmpty || isBusy)
                Button("Clean up V4.1 downloads…") { confirming41Cleanup = true }
                    .disabled(removableFlash41CleanupQuants.isEmpty || isBusy)
            } header: {
                Text("Downloads")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Downloads use 64 connections instead of 8. Leave off behind CGNAT or strict NAT.")
                    Text(cleanupFooter)
                }
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

        }
        .formStyle(.grouped)
        .frame(width: 600, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            contentHeight = height
        }
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
