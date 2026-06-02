import SwiftUI

struct ModelRowView: View {
    @ObservedObject var supervisor: SupervisorService
    @EnvironmentObject var app: AppState
    let ramGiB: Double

    private var variants: [Variant] { ramGiB >= 512 ? [.pro, .flash] : [.flash] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $app.selectedVariant) {
                ForEach(variants) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(supervisor.state == .downloading)  // don't switch model mid-download

            let feas = feasibility(ramGiB: ramGiB, variant: app.selectedVariant)
            actionButton(feas)
            feasibilityNote(feas)
        }
    }

    @ViewBuilder private func actionButton(_ feas: Feasibility) -> some View {
        let downloaded = supervisor.isDownloaded(app.selectedVariant, flashQuant: app.selectedFlashQuant)
        let blocked: Bool = {
            if case .blocked = feas { return true }
            return false
        }()
        switch supervisor.state {
        case .ready, .starting:
            Button("Stop") { supervisor.stop() }.tint(.red).frame(maxWidth: .infinity)
        case .downloading:
            // Retry restarts the download (escape hatch from a stalled bar); Cancel stops it.
            HStack {
                Button("Retry download") {
                    supervisor.retryDownload(
                        variant: app.selectedVariant, flashQuant: app.selectedFlashQuant,
                        highPerformance: app.highPerformanceDownload)
                }
                .tint(.orange).frame(maxWidth: .infinity).disabled(blocked)
                Button("Cancel", role: .destructive) { supervisor.cancelDownload() }
                    .frame(maxWidth: .infinity)
            }
        case .error:
            Button(downloaded ? "Retry" : "Retry download") {
                if downloaded {
                    supervisor.start(
                        variant: app.selectedVariant, flashQuant: app.selectedFlashQuant,
                        ctx: app.effectiveCtx(ramGiB: ramGiB),
                        port: app.port, power: app.power)
                } else {
                    supervisor.retryDownload(
                        variant: app.selectedVariant, flashQuant: app.selectedFlashQuant,
                        highPerformance: app.highPerformanceDownload)
                }
            }
            .tint(.orange).frame(maxWidth: .infinity).disabled(blocked)
        default:
            if !downloaded {
                Button("Download \(app.selectedVariant.displayName)") {
                    supervisor.download(
                        variant: app.selectedVariant, flashQuant: app.selectedFlashQuant,
                        highPerformance: app.highPerformanceDownload)
                }
                .frame(maxWidth: .infinity).disabled(blocked)
            } else {
                Button("Start") {
                    supervisor.start(
                        variant: app.selectedVariant, flashQuant: app.selectedFlashQuant,
                        ctx: app.effectiveCtx(ramGiB: ramGiB),
                        port: app.port, power: app.power,
                        kvDiskDir: app.kvDiskCache ? supervisor.kvDiskCacheURL : nil)
                }.frame(maxWidth: .infinity).disabled(blocked)
            }
        }
    }

    @ViewBuilder private func feasibilityNote(_ feas: Feasibility) -> some View {
        switch feas {
        case .standard: EmptyView()
        case let .warnWiredLimit(mb):
            // Hide once the user has already raised the wired limit to (at least) the
            // recommended value — re-read live, so it disappears within a metrics tick.
            if currentWiredLimitMB() >= mb {
                EmptyView()
            } else {
                Text(
                    (app.selectedVariant == .pro
                        ? "V4 Pro needs the Metal wired limit raised for its weights + context:"
                        : "96–127 GiB: reduced context, ~25–27 tok/s. Raise the Metal wired limit:")
                        + "\nsudo sysctl iogpu.wired_limit_mb=\(mb)"
                )
                .font(.caption2).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .blocked(reason):
            Text(reason).font(.caption2).foregroundStyle(.red)
        }
    }
}
