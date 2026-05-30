import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    private let ram = systemRamGiB()

    var body: some View {
        Form {
            Section("ds4 directory") {
                HStack {
                    TextField("Path to ds4 (contains ds4-server + download_model.sh)", text: $app.ds4Dir)
                    Button("Choose…") { pickDir() }
                }
            }
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
            }
            if ram < 96 {
                Section("Advanced") {
                    Toggle("Enable unsupported low-RAM mode", isOn: $app.unsupportedLowRAM)
                    Text("Below 96 GiB is not a supported configuration; ds4 may swap or crash.")
                        .font(.caption2).foregroundStyle(.red)
                }
            }
        }
        .padding(20).frame(width: 420)
    }

    private func pickDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { app.ds4Dir = url.path }
    }
}
