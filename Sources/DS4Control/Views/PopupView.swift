import SwiftUI

struct PopupView: View {
    @EnvironmentObject var supervisor: SupervisorService
    @EnvironmentObject var metrics: MetricsManager
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    private let ram = systemRamGiB()
    @State private var showStartHint = false
    @State private var showDownloadHint = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            ModelRowView(supervisor: supervisor, ramGiB: ram)
            legacyWeightsBanner
            if supervisor.state == .downloading, let d = supervisor.download {
                ProgressView(value: d.pct, total: 100) {
                    HStack(spacing: 6) {
                        // Live spinner: shown only while a download process is confirmed running.
                        if supervisor.downloadProcessLive {
                            ProgressView().progressViewStyle(.circular).controlSize(.small)
                        }
                        Text(d.file).font(.caption2).lineLimit(1).truncationMode(.middle)
                    }
                } currentValueLabel: {
                    Text(downloadStatusLabel(d)).font(.caption2)
                }
            }
            if case let .error(e) = supervisor.state {
                errorBanner(e)
            }
            Divider()
            cards
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(stateColor).frame(width: 8, height: 8)
            Text("DS4 Control").font(.headline)
            Spacer()
            Text(stateLabel).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var cards: some View {
        if let s = metrics.currentSnapshot {
            MetricCardView(
                title: "Unified Memory", icon: "memorychip",
                value: String(format: "%.0f%%", s.memory.usagePercent),
                subtitle: gb(s.memory.usedBytes) + " / " + gb(s.memory.totalBytes),
                severity: .from(percent: s.memory.usagePercent, warningAt: 85, criticalAt: 95),
                sparklineData: metrics.history.memory(), accentColor: .blue,
                sparklineFixedRange: (0, 100), emphasized: true, gaugeFraction: s.memory.usagePercent / 100,
                severityColorOverride: s.memory.usagePercent >= 95 ? .yellow : nil)
            HStack(spacing: 10) {
                MetricCardView(
                    title: "GPU", icon: "cpu",
                    value: String(format: "%.0f%%", s.gpu.utilizationPercent), subtitle: "\(s.gpu.coreCount) cores",
                    severity: .from(percent: s.gpu.utilizationPercent),
                    sparklineData: metrics.history.gpu(), accentColor: .purple,
                    sparklineFixedRange: (0, 100), compact: true)
                MetricCardView(
                    title: "CPU", icon: "cpu",
                    value: String(format: "%.0f%%", s.cpu.totalUsage), subtitle: "\(s.cpu.coreCount) cores",
                    severity: .from(percent: s.cpu.totalUsage),
                    sparklineData: metrics.history.cpu(), accentColor: .green,
                    sparklineFixedRange: (0, 100), compact: true)
            }
            if let p = s.power {
                MetricCardView(
                    title: "Power", icon: "bolt.fill",
                    value: String(format: "%.1f W", p.totalPowerWatts),
                    subtitle: String(
                        format: "CPU %.1f · GPU %.1f · ANE %.1f", p.cpuPowerWatts, p.gpuPowerWatts, p.anePowerWatts),
                    severity: .normal, sparklineData: metrics.history.power(), accentColor: .orange, compact: true)
            }
        } else {
            HStack {
                Spacer(); ProgressView().controlSize(.small); Text("Collecting…").font(.caption); Spacer()
            }
        }
    }

    /// "v1.0.2 (162)" from the bundle's short version + build, shown under Quit. Falls back to
    /// "dev build" when run without a packaged Info.plist (e.g. `swift run`).
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "dev build" }
        if let build = info?["CFBundleVersion"] as? String, build != short { return "v\(short) (\(build))" }
        return "v\(short)"
    }

    private var footer: some View {
        // Inline hint rather than a modal: a `.window` MenuBarExtra dismisses when it
        // resigns key, so an .alert/sheet would collapse the whole popover.
        VStack(alignment: .leading, spacing: 6) {
            if showStartHint && supervisor.state != .ready {
                Text("Start the model first to use chat and a coding agent.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if showDownloadHint && supervisor.state == .downloading {
                Text("Settings are locked while a download is in progress.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button {
                    if supervisor.state == .downloading {
                        showDownloadHint = true
                    } else {
                        WindowChrome.willOpenWindow()
                        openWindow(id: "settings")
                    }
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 28))
                }.buttonStyle(.plain).help("Settings")
                Button {
                    if supervisor.state == .ready {
                        WindowChrome.willOpenWindow()
                        openWindow(id: "chat")
                    } else {
                        showStartHint = true
                    }
                } label: {
                    Image(systemName: "bubble.left").font(.system(size: 28))
                }.buttonStyle(.plain).help("Open chat")
                Button {
                    if supervisor.state == .ready {
                        AgentLauncher.launch(
                            port: supervisor.port,
                            modelId: AgentLauncher.modelId(
                                for: supervisor.activeModel, fallback: app.selectedVariant),
                            contextWindow: supervisor.ctx,
                            allowMaxThink: supportsMaxThink(ramGiB: ram)
                                && thinkMax(ctx: supervisor.ctx))
                    } else {
                        showStartHint = true
                    }
                } label: {
                    Image(systemName: "terminal").font(.system(size: 28))
                }.buttonStyle(.plain).help("Open a coding agent in Terminal")
                // Dev/test-only shortcut: production users reach the help window from
                // the gated-Start notice instead.
                if emulatedWiredLimitMB() != nil || isDevBuild() {
                    Button {
                        WindowChrome.willOpenWindow()
                        openWindow(id: "wiredhelp")
                    } label: {
                        Image(systemName: "questionmark.circle").font(.system(size: 28))
                    }.buttonStyle(.plain).help("Metal wired memory limit help")
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Text(Self.appVersion)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("DS4 Control version")
            }
        }
        .onChange(of: supervisor.state) { _, newState in
            if newState == .ready { showStartHint = false }
        }
    }

    @ViewBuilder private func errorBanner(_ e: ServerError) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(errorMessage(e)).font(.caption2).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One-time banner for the pre-0731 weights migration. Only while idle/error — a
    /// running or downloading model is never touched (same gating as Settings cleanup).
    private var showLegacyWeightsBanner: Bool {
        if app.legacyWeightsPromptDismissed { return false }
        switch supervisor.state {
        case .idle, .error: break
        default: return false
        }
        return supervisor.legacyPreviewGgufBytes() > 0
    }

    @ViewBuilder private var legacyWeightsBanner: some View {
        if showLegacyWeightsBanner {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        "Old V4 Flash preview weights found"
                            + " (~\(supervisor.legacyPreviewGgufBytes() / 1_073_741_824) GiB). "
                            + "The 0731 models replaced them — they can no longer be started."
                    )
                    .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button("Delete old weights") { confirmLegacyWeightsDelete() }
                        Button("Not now") { app.legacyWeightsPromptDismissed = true }
                    }
                    .font(.caption2)
                }
            }
        }
    }

    /// Real NSAlert (not SwiftUI .alert, which would collapse the .window MenuBarExtra).
    /// The app promotes to .regular while it's up — the same dance WindowChrome does for
    /// the chat/settings windows. The accessory view is the textarea listing the files.
    private func confirmLegacyWeightsDelete() {
        let paths = supervisor.legacyPreviewGgufURLs().map(\.path)
        guard !paths.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Delete these \(paths.count) file(s)?"
        alert.informativeText =
            "Old V4 Flash preview weights"
            + " (~\(supervisor.legacyPreviewGgufBytes() / 1_073_741_824) GiB). This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""  // keep Cancel as the Return-key default
        alert.buttons[1].keyEquivalent = "\r"
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 96))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .lineBorder
        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = paths.joined(separator: "\n\n")
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        alert.accessoryView = scrollView
        WindowChrome.windowOpened(title: "ds4-legacy-delete-confirmation")  // policy → .regular
        NSApplication.shared.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        WindowChrome.windowClosed()
        if response == .alertFirstButtonReturn {
            supervisor.removeLegacyPreviewGgufs()
            // Dismiss only when nothing is left: a failed deletion keeps the banner up so the
            // user can retry ("Not now" remains the deliberate opt-out).
            app.legacyWeightsPromptDismissed = supervisor.legacyPreviewGgufURLs().isEmpty
        }
    }

    private func errorMessage(_ e: ServerError) -> String {
        switch e {
        case let .ds4DirInvalid(missing): return "ds4 files not found — missing \(missing). Reinstall the app."
        case let .modelMissing(filename): return "Model not downloaded (\(filename)). Use Download first."
        case .startupTimeout: return "ds4-server didn't become ready in time."
        case .unhealthy: return "ds4-server stopped responding."
        case let .crashed(tail): return "ds4-server exited unexpectedly. \(tail.suffix(160))"
        case let .downloadFailed(detail): return "Download failed (\(detail))."
        case let .badState(message): return message
        case let .configurationBlocked(reason): return reason
        case let .wiredLimitTooLow(requiredMB, _):
            return
                "Metal wired limit is below this config's ~\(roundedUpGiB(fromMB: requiredMB)) GiB working set. "
                + "Use \"Metal wired limit help…\" under Start to fix it."
        }
    }

    private func downloadStatusLabel(_ d: DownloadProgress) -> String {
        var parts = [String(format: "%.0f%%", d.pct)]
        if let total = d.totalBytes, total > 0 {
            parts.append(String(format: "%.0f/%.0f GB", Double(d.receivedBytes) / 1e9, Double(total) / 1e9))
        }
        if let rate = d.rate { parts.append(rate) }
        return parts.joined(separator: " · ")
    }

    private func gb(_ b: UInt64) -> String { String(format: "%.0f GB", Double(b) / 1_073_741_824) }
    private var stateColor: Color {
        switch supervisor.state {
        case .ready: return .green
        case .starting, .downloading: return .orange
        case .error: return .red
        default: return .gray
        }
    }
    private var stateLabel: String {
        switch supervisor.state {
        case .idle: return "Idle"
        case .downloading: return "Downloading"
        case .starting: return "Starting"
        case .ready:
            return "\(supervisor.activeModel ?? "") · :\(supervisor.port)"
        case .stopping: return "Stopping"
        case .error: return "Error"
        }
    }
}
