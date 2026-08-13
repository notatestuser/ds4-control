import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var supervisor: SupervisorService
    private let ram = systemRamGiB()
    @State private var confirmingCleanup = false

    private var isRunning: Bool { supervisor.state == .ready || supervisor.state == .starting }
    /// Busy = a server is running/starting/stopping or a download is in flight; cleanup is
    /// disabled then so an in-use or downloading model is never removed.
    private var isBusy: Bool {
        switch supervisor.state {
        case .idle, .error: return false
        default: return true
        }
    }
    /// Downloaded same-family models other than the selected one — candidates for cleanup.
    /// V4 Pro is excluded by construction (never deleted); Laguna is the only model in its
    /// family, so nothing is ever removable there.
    private var removableModels: [Model] {
        Model.allCases.filter {
            $0 != app.selectedModel && $0 != .v4Pro && $0.quant != nil && supervisor.isDownloaded($0)
        }
    }
    private var removableFreedGiB: Int {
        Int(removableModels.reduce(0.0) { $0 + $1.weightsGiB })
    }
    private var modelFooter: String {
        let base =
            "Which model to download and run. Sizes are running memory; "
            + "options that don't fit this Mac's RAM are unavailable."
        return isBusy
            ? base + " Stop the server to delete unused downloads."
            : base + " Clean up deletes other downloaded V4 Flash variants (V4 Pro and other families are always kept)."
    }

    private var ctxHint: String {
        if app.ctxOverride > 0 {
            if !supportsMaxThink(ramGiB: ram) {
                return "Max Think is unavailable below 128 GiB unified memory."
            }
            return "Max Think is available when context ≥ 393,216."
        }
        return
            "Auto: \(defaultCtx(ramGiB: ram, model: app.selectedModel).formatted()) tokens (based on \(Int(ram)) GiB RAM)."
    }

    private var thinkingHint: String {
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

    private var powerBinding: Binding<Double> {
        Binding(get: { Double(app.power ?? 100) }, set: { app.power = Int($0.rounded()) })
    }
    private var sessionsBinding: Binding<Double> {
        Binding(get: { Double(app.concurrentSessions) }, set: { app.concurrentSessions = Int($0.rounded()) })
    }
    private var streamingCacheBinding: Binding<Double> {
        Binding(get: { Double(app.ssdStreamingCacheGB) }, set: { app.ssdStreamingCacheGB = Int($0.rounded()) })
    }
    private var streamingCacheMaxGiB: Int {
        let expertGiB = app.selectedModel.quant?.routedExpertGiB ?? Quant.q2q4Imatrix.routedExpertGiB
        return max(17, Int(expertGiB) - 1)
    }
    private var streamingCaption: String {
        guard let expertGiB = app.selectedModel.quant?.routedExpertGiB else { return "" }  // Laguna: N/A
        let gb = app.ssdStreamingCacheGB
        // Truncates (82.69 − 67 → ~15 GiB); clamps at 0 so a saved budget larger than
        // the current quant's experts (e.g. after switching quant) never shows negative.
        let freed = max(0, Int(expertGiB - Double(gb)))
        return
            "Expert cache \(gb) GiB — frees ~\(freed) GiB of RAM from model weights. "
            + "Decode can be slower when the SSD must refill the cache."
    }
    /// Context-size field as text. Always shows the active window: the override if set, else the
    /// tiered default — so the box is never blank. Backspacing it away stores 0 (auto), which the
    /// getter immediately re-renders as the default value.
    private var ctxText: Binding<String> {
        Binding(
            get: {
                String(app.effectiveCtx(ramGiB: ram))            },
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
                Toggle("Stream expert weights from SSD", isOn: $app.ssdStreaming)
                    .disabled(!app.selectedModel.supportsSSDStreaming)
                if app.selectedModel.supportsSSDStreaming {
                    if app.ssdStreaming {
                        LabeledContent {
                            HStack(spacing: 10) {
                                Slider(value: streamingCacheBinding, in: 16...Double(streamingCacheMaxGiB), step: 1)
                                Text("\(app.ssdStreamingCacheGB)")
                                    .monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 30, alignment: .trailing)
                            }
                            .frame(width: 230)
                        } label: {
                            Text("Expert cache")
                        }
                        Text(streamingCaption)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(
                        "SSD streaming isn't supported for Laguna S 2.1 on this ds4 yet — "
                            + "passing the flag would make the server refuse to start."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("SSD streaming")
            } footer: {
                Text(
                    "Keeps only part of the routed expert weights in RAM and streams the rest "
                        + "from disk on demand, freeing memory for other apps. "
                        + "Applies on next server start or restart.")
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
                Picker("Model", selection: $app.selectedModel) {
                    ForEach(Model.allCases) { m in
                        Text(m.label + (supervisor.isDownloaded(m) ? "  (downloaded)" : ""))
                            .tag(m)
                            .disabled(blocked(m))
                    }
                }
                .disabled(supervisor.state == .downloading)  // locked while a download is in progress
                Button("Clean up unused downloads") { confirmingCleanup = true }
                    .disabled(removableModels.isEmpty || isBusy)
            } header: {
                Text("Model")
            } footer: {
                Text(modelFooter)
            }
            .confirmationDialog(
                "Delete other V4 Flash downloads?", isPresented: $confirmingCleanup,
                titleVisibility: .visible
            ) {
                Button(
                    "Delete \(removableModels.count) file(s) · ~\(removableFreedGiB) GiB",
                    role: .destructive
                ) {
                    supervisor.cleanupUnusedModels(keep: app.selectedModel)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Keeps the selected model, V4 Pro, and other families. Deleted weights must be downloaded again.")
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
            model: app.selectedModel,            ctx: app.effectiveCtx(ramGiB: ram),
            host: host, port: app.port, power: app.power,
            sessions: app.concurrentSessions,
            kvDiskDir: app.kvDiskCache ? supervisor.kvDiskCacheURL : nil,
            overrideWiredLimitGate: overrideWiredLimitGate,
            ssdStreaming: app.ssdStreaming, ssdStreamingCacheGB: app.ssdStreamingCacheGB)
        if case let .rejected(feasibility) = result {
            RestartRejectionAlert.show(
                feasibility,
                contextSentence: "The current server is still running."
            ) {
                restart(overrideWiredLimitGate: true)
            }
        }
    }

    private func blocked(_ m: Model) -> Bool {
        if case .blocked = feasibility(ramGiB: ram, model: m) { return true }
        return false
    }
}
