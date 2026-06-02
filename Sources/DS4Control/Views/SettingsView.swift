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
    /// Downloaded Flash quants other than the selected one — candidates for cleanup.
    private var removableFlashQuants: [FlashQuant] {
        FlashQuant.allCases.filter { $0 != app.selectedFlashQuant && supervisor.isFlashQuantDownloaded($0) }
    }
    private var removableFreedGiB: Int {
        Int(removableFlashQuants.reduce(0.0) { $0 + $1.quant.weightsGiB })
    }
    private var flashModelFooter: String {
        let base =
            "Which V4 Flash quant to download and run. Larger quants need more memory; "
            + "options that exceed this machine's RAM are disabled."
        return isBusy
            ? base + " Stop the server to clean up unused downloads."
            : base + " Clean up removes other downloaded Flash quants (V4 Pro is always kept)."
    }

    private var ctxHint: String {
        if app.ctxOverride > 0 {
            return thinkMax(ctx: app.ctxOverride)
                ? "Think-Max active (context ≥ 393,216)." : "Below Think-Max."
        }
        return
            "Auto: \(defaultCtx(ramGiB: ram, variant: app.selectedVariant, flashQuant: app.selectedFlashQuant).formatted()) tokens for \(Int(ram)) GiB."
    }

    private var restartHint: String {
        isRunning
            ? "Stops and relaunches ds4-server now with these settings."
            : "Server not running — these settings apply when you next Start it."
    }

    private var powerBinding: Binding<Double> {
        Binding(get: { Double(app.power ?? 100) }, set: { app.power = Int($0.rounded()) })
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
                        "Disk KV cache persists the cache so repeated or large prompts skip re-prefill "
                            + "— applied on next Start.")
                }
            }

            Section {
                Button("Apply & Restart Server", action: restart)
                    .disabled(!isRunning)
            } footer: {
                Text(restartHint)
            }

            Section {
                Toggle("Enable Think Max in chat", isOn: $app.thinkMaxChat)
            } header: {
                Text("Chat")
            } footer: {
                Text(
                    "Sends reasoning_effort=max so the built-in chat runs DeepSeek's Think Max. "
                        + "Off uses the fast non-thinking path. Coding-agent CLIs set their own "
                        + "thinking level, so this affects only the chat.")
            }

            Section {
                Picker("Quant", selection: $app.selectedFlashQuant) {
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
                Text("Keeps the selected quant and V4 Pro. Cannot be undone — removed quants must be re-downloaded.")
            }

            Section {
                Toggle("High performance mode", isOn: $app.highPerformanceDownload)
            } header: {
                Text("Downloads")
            } footer: {
                Text(
                    "Maximises speed with wide parallel connections. Leave off behind CGNAT or strict NAT — "
                        + "the connection storm can exhaust the session table and knock you offline."
                )
            }

        }
        .formStyle(.grouped)
        .frame(width: 480, height: 600)
        .onAppear { WindowChrome.windowOpened(title: "DS4 Control Settings") }
        .onDisappear { WindowChrome.windowClosed() }
    }

    private func restart() {
        supervisor.restart(
            variant: app.selectedVariant, flashQuant: app.selectedFlashQuant,
            ctx: app.effectiveCtx(ramGiB: ram),
            port: app.port, power: app.power,
            kvDiskDir: app.kvDiskCache ? supervisor.kvDiskCacheURL : nil)
    }
}
