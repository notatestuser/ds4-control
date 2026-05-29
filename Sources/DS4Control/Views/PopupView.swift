import SwiftUI

struct PopupView: View {
    @EnvironmentObject var supervisor: SupervisorService
    @EnvironmentObject var metrics: MetricsManager
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    private let ram = systemRamGiB()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            ModelRowView(supervisor: supervisor, ramGiB: ram)
            if supervisor.state == .downloading, let d = supervisor.download {
                ProgressView(value: d.pct, total: 100) {
                    Text(d.file).font(.caption2).lineLimit(1).truncationMode(.middle)
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
                sparklineFixedRange: (0, 100), emphasized: true, gaugeFraction: s.memory.usagePercent / 100)
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

    private var footer: some View {
        HStack {
            Button {
                openWindow(id: "settings")
            } label: {
                Image(systemName: "gearshape")
            }.buttonStyle(.plain)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func errorBanner(_ e: ServerError) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(errorMessage(e)).font(.caption2).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func errorMessage(_ e: ServerError) -> String {
        switch e {
        case let .ds4DirInvalid(missing): return "ds4 directory invalid — missing \(missing). Set it in Settings."
        case let .modelMissing(filename): return "Model not downloaded (\(filename)). Use Download first."
        case .startupTimeout: return "ds4-server didn't become ready in time."
        case .unhealthy: return "ds4-server stopped responding."
        case let .crashed(tail): return "ds4-server exited unexpectedly. \(tail.suffix(160))"
        case let .downloadFailed(detail): return "Download failed (\(detail))."
        case let .badState(message): return message
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
                + (supervisor.thinkMaxActive ? " · Think-Max" : "")
        case .stopping: return "Stopping"
        case .error: return "Error"
        }
    }
}
