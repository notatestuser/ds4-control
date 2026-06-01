import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var supervisor: SupervisorService
    private let ram = systemRamGiB()

    private var isRunning: Bool { supervisor.state == .ready || supervisor.state == .starting }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Context size", value: $app.ctxOverride, format: .number)
                Text(
                    app.ctxOverride > 0
                        ? (thinkMax(ctx: app.ctxOverride) ? "Think-Max active (≥393216)" : "Below Think-Max")
                        : "Auto: \(defaultCtx(ramGiB: ram, variant: app.selectedVariant)) for \(Int(ram)) GiB"
                )
                .font(.caption).foregroundStyle(.secondary)
                TextField("Port", value: $app.port, format: .number)
                Stepper(
                    "GPU power duty: \(app.power ?? 100)",
                    value: Binding(
                        get: { app.power ?? 100 }, set: { app.power = $0 }), in: 1...100)
                Toggle("Disk KV cache", isOn: $app.kvDiskCache)
                Text(
                    "Persists the KV cache to disk so repeated or large prompts skip re-prefill. Applied on next Start."
                )
                .font(.caption2).foregroundStyle(.secondary)

                Button("Apply & Restart Server") {
                    supervisor.restart(
                        variant: app.selectedVariant,
                        ctx: app.effectiveCtx(ramGiB: ram),
                        port: app.port, power: app.power,
                        kvDiskDir: app.kvDiskCache ? supervisor.ds4Dir.appendingPathComponent(".ds4-kv") : nil)
                }
                .disabled(!isRunning)
                Text(
                    isRunning
                        ? "Stops and relaunches ds4-server now with these settings."
                        : "Server not running — these settings apply when you next Start it."
                )
                .font(.caption2).foregroundStyle(.secondary)
            }
            Section("Downloads") {
                Toggle("High performance mode", isOn: $app.highPerformanceDownload)
                Text(
                    "Maximises speed with wide parallel connections. Leave off behind CGNAT or strict NAT — "
                        + "the connection storm can exhaust the session table and knock you offline."
                )
                .font(.caption2).foregroundStyle(.secondary)
            }
            if ram < 96 {
                Section("Advanced") {
                    Toggle("Enable unsupported low-RAM mode", isOn: $app.unsupportedLowRAM)
                    Text("Below 96 GiB is not a supported configuration; ds4 may swap or crash.")
                        .font(.caption2).foregroundStyle(.red)
                }
            }
        }
        .padding(20).frame(width: 560)
        .onAppear { WindowChrome.windowOpened(title: "DS4 Control Settings") }
        .onDisappear { WindowChrome.windowClosed() }
    }
}
