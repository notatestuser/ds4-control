import SwiftUI

struct ModelRowView: View {
    @ObservedObject var supervisor: SupervisorService
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
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

            let feas = feasibility(
                ramGiB: ramGiB, variant: app.selectedVariant, flashQuant: app.selectedFlashQuant,
                ctx: app.effectiveCtx(ramGiB: ramGiB),
                wiredLimitMB: effectiveWiredLimitMB(ramGiB: ramGiB),
                sessions: app.concurrentSessions)
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
        // Working set over the effective wired limit: Start stays available only behind a
        // confirmed "Start anyway" (the popup note explains the fix).
        let wiredLow: Bool = {
            if case .wiredLimitTooLow = feas { return true }
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
            Button(downloaded ? (wiredLow ? "Start anyway…" : "Retry") : "Retry download") {
                if downloaded {
                    wiredLow ? confirmStartAnyway() : startServer(overrideWiredLimitGate: false)
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
                Button(wiredLow ? "Start anyway…" : "Start") {
                    wiredLow ? confirmStartAnyway() : startServer(overrideWiredLimitGate: false)
                }
                .tint(wiredLow ? .orange : .accentColor)
                .frame(maxWidth: .infinity).disabled(blocked)
            }
        }
    }

    private func startServer(overrideWiredLimitGate: Bool) {
        let host = app.normalizeHostForLaunch()
        supervisor.start(
            variant: app.selectedVariant, flashQuant: app.selectedFlashQuant,
            ctx: app.effectiveCtx(ramGiB: ramGiB),
            host: host, port: app.port, power: app.power,
            sessions: app.concurrentSessions,
            kvDiskDir: app.kvDiskCache ? supervisor.kvDiskCacheURL : nil,
            overrideWiredLimitGate: overrideWiredLimitGate)
    }

    /// Real NSAlert (not SwiftUI .alert, which would collapse the .window MenuBarExtra) —
    /// same dance as PopupView's legacy-weights confirmation. Cancel stays the default so
    /// a stray Return doesn't launch a config that hangs the machine.
    private func confirmStartAnyway() {
        let alert = NSAlert()
        alert.messageText = "Start anyway?"
        alert.informativeText =
            "The Metal wired memory limit is below what this model needs, so macOS will page it "
            + "and the server will likely hang while memory pegs near 100%. "
            + "Raise the limit first (see \"Metal wired limit help…\" below) unless you know this works on your setup."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Start anyway")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""  // keep Cancel as the Return-key default
        alert.buttons[1].keyEquivalent = "\r"
        WindowChrome.windowOpened(title: "ds4-wired-limit-start-anyway")
        NSApplication.shared.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        WindowChrome.windowClosed()
        if response == .alertFirstButtonReturn { startServer(overrideWiredLimitGate: true) }
    }

    @ViewBuilder private func feasibilityNote(_ feas: Feasibility) -> some View {
        switch feas {
        case .standard: EmptyView()
        case let .wiredLimitTooLow(requiredMB, advisoryMB):
            // Re-read live (metrics tick), so raising the limit in Terminal clears this
            // within ~2 s — no app restart needed.
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "Metal wired limit too low: this setup needs ~\(roundedUpGiB(fromMB: requiredMB)) GiB but the GPU can wire "
                        + "~\(effectiveWiredLimitMB(ramGiB: ramGiB) / 1024) GiB. Raise it in Terminal:"
                )
                Text("sudo sysctl iogpu.wired_limit_mb=\(advisoryMB)")
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                Button {
                    WindowChrome.willOpenWindow()
                    openWindow(id: "wiredhelp")
                } label: {
                    Label("Metal wired limit help…", systemImage: "questionmark.circle")
                }
                .buttonStyle(.link).font(.caption2)
            }
            .font(.caption2).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        case let .blocked(reason):
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
