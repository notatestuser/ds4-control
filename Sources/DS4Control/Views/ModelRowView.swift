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

            let feas = feasibility(ramGiB: ramGiB, variant: app.selectedVariant)
            actionButton(feas)
            feasibilityNote(feas)
        }
    }

    @ViewBuilder private func actionButton(_ feas: Feasibility) -> some View {
        let downloaded = supervisor.isDownloaded(app.selectedVariant)
        let blocked: Bool = {
            switch feas {
            case .blocked: return true
            case .unsupported: return !app.unsupportedLowRAM
            default: return false
            }
        }()
        switch supervisor.state {
        case .ready, .starting:
            Button("Stop") { supervisor.stop() }.tint(.red).frame(maxWidth: .infinity)
        case .downloading:
            Button("Downloading…") {}.disabled(true).frame(maxWidth: .infinity)
        default:
            if !downloaded {
                Button("Download \(app.selectedVariant.displayName)") {
                    supervisor.download(variant: app.selectedVariant)
                }
                .frame(maxWidth: .infinity).disabled(blocked)
            } else {
                Button("Start") {
                    supervisor.start(
                        variant: app.selectedVariant,
                        ctx: app.effectiveCtx(ramGiB: ramGiB),
                        port: app.port, power: app.power)
                }.frame(maxWidth: .infinity).disabled(blocked)
            }
        }
    }

    @ViewBuilder private func feasibilityNote(_ feas: Feasibility) -> some View {
        switch feas {
        case .standard: EmptyView()
        case let .warnWiredLimit(mb):
            Text(
                "96–127 GiB: reduced context, ~25–27 tok/s. Raise the Metal wired limit:\nsudo sysctl iogpu.wired_limit_mb=\(mb)"
            )
            .font(.caption2).foregroundStyle(.orange)
        case let .blocked(reason):
            Text(reason).font(.caption2).foregroundStyle(.red)
        case let .unsupported(reason):
            VStack(alignment: .leading, spacing: 2) {
                Text("UNSUPPORTED — may swap or crash").font(.caption2.bold()).foregroundStyle(.red)
                Text(reason).font(.caption2).foregroundStyle(.secondary)
                Toggle("Enable unsupported low-RAM mode", isOn: $app.unsupportedLowRAM).font(.caption2)
            }
        }
    }
}
