import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var supervisor: SupervisorService
    private let ram = systemRamGiB()

    private var isRunning: Bool { supervisor.state == .ready || supervisor.state == .starting }

    private var ctxHint: String {
        if app.ctxOverride > 0 {
            return thinkMax(ctx: app.ctxOverride)
                ? "Think-Max active (context ≥ 393,216)." : "Below Think-Max."
        }
        return "Auto: \(defaultCtx(ramGiB: ram, variant: app.selectedVariant).formatted()) tokens for \(Int(ram)) GiB."
    }

    private var restartHint: String {
        isRunning
            ? "Stops and relaunches ds4-server now with these settings."
            : "Server not running — these settings apply when you next Start it."
    }

    private var powerBinding: Binding<Double> {
        Binding(get: { Double(app.power ?? 100) }, set: { app.power = Int($0.rounded()) })
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    TextField("", value: $app.ctxOverride, format: .number)
                        .labelsHidden().multilineTextAlignment(.trailing).frame(width: 130)
                } label: {
                    Text("Context size")
                }
                LabeledContent {
                    TextField("", value: $app.port, format: .number)
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
                Toggle("High performance mode", isOn: $app.highPerformanceDownload)
            } header: {
                Text("Downloads")
            } footer: {
                Text(
                    "Maximises speed with wide parallel connections. Leave off behind CGNAT or strict NAT — "
                        + "the connection storm can exhaust the session table and knock you offline."
                )
            }

            if ram < 96 {
                Section {
                    Toggle("Enable unsupported low-RAM mode", isOn: $app.unsupportedLowRAM)
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Below 96 GiB is not a supported configuration; ds4 may swap or crash.")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
        .onAppear { WindowChrome.windowOpened(title: "DS4 Control Settings") }
        .onDisappear { WindowChrome.windowClosed() }
    }

    private func restart() {
        supervisor.restart(
            variant: app.selectedVariant,
            ctx: app.effectiveCtx(ramGiB: ram),
            port: app.port, power: app.power,
            kvDiskDir: app.kvDiskCache ? supervisor.kvDiskCacheURL : nil)
    }
}
