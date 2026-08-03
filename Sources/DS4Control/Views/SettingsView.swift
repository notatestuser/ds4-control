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
            } header: {
                Text("Chat")
            } footer: {
                Text(
                    "Max Think needs a context of at least 393,216 — you'll be asked to raise it. "
                        + "Coding agents set their own level; this only affects the built-in chat.")
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
        .onAppear { WindowChrome.windowOpened(title: "DS4 Control Settings") }
        .onDisappear { WindowChrome.windowClosed() }
    }

    private func restart() {
        let host = app.normalizeHostForLaunch()
        supervisor.restart(
            variant: app.selectedVariant, flashQuant: app.selectedFlashQuant,
            ctx: app.effectiveCtx(ramGiB: ram),
            host: host, port: app.port, power: app.power,
            sessions: app.concurrentSessions,
            kvDiskDir: app.kvDiskCache ? supervisor.kvDiskCacheURL : nil)
    }
}
