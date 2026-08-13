import SwiftUI

func wiredLimitPersistenceScript(advisoryMB: Int) -> String {
    "touch \"$1\" && tmp=$(mktemp) && trap \"rm -f \\\"$tmp\\\"\" 0 && awk \"!/^[[:space:]]*iogpu[.]wired_limit_mb[[:space:]]*=/\" \"$1\" > \"$tmp\" && printf \"%s\\n\" \"iogpu.wired_limit_mb=\(advisoryMB)\" >> \"$tmp\" && cat \"$tmp\" > \"$1\""
}

func wiredLimitPersistenceCommand(advisoryMB: Int) -> String {
    "sudo sh -c '\(wiredLimitPersistenceScript(advisoryMB: advisoryMB))' sh /etc/sysctl.conf"
}

func boundedWiredRequirementMB(_ requiredMB: Int) -> Int? {
    requiredMB == Int.max ? nil : requiredMB
}

/// Walkthrough window for the Metal wired memory limit: why the gate fired, the exact
/// sysctl to fix it, and how to make it survive reboots (the sysctl resets on every
/// restart — the classic "it worked before, now it hangs" trap). Opened from the popup's
/// gated-Start note.
struct WiredLimitHelpView: View {
    @EnvironmentObject var app: AppState
    private let ramGiB = systemRamGiB()
    @State private var copiedCommand: String?
    /// Measured content height — the window opens tall enough to show everything at once.
    @State private var contentHeight: CGFloat = 0

    private var advisoryMB: Int {
        max(wiredLimitAdvisoryMB(ramGiB: ramGiB), requiredMB ?? 0)
    }
    private var advisoryNote: String {
        if advisoryMB == wiredLimitAdvisoryMB(ramGiB: ramGiB) {
            return "\(advisoryMB) MB leaves ~\(Int(osReserveGiB)) GiB for macOS."
        }
        return
            "\(advisoryMB) MB is the minimum for this setup; reduce context or concurrent sessions if macOS needs more headroom."
    }
    private var sysctlCommand: String { "sudo sysctl iogpu.wired_limit_mb=\(advisoryMB)" }
    private var persistCommand: String {
        wiredLimitPersistenceCommand(advisoryMB: advisoryMB)
    }

    private var requiredMB: Int? {
        boundedWiredRequirementMB(
            requiredWiredMB(
                variant: app.selectedVariant, flashQuant: app.selectedFlashQuant,
                ctx: app.effectiveCtx(ramGiB: ramGiB), sessions: app.concurrentSessions))
    }

    private var requiredMemoryLabel: String {
        guard let requiredMB else { return "more than any Mac provides" }
        return "~\(roundedUpGiB(fromMB: requiredMB)) GiB"
    }

    private var blockedReason: String? {
        let result = feasibility(
            ramGiB: ramGiB, variant: app.selectedVariant,
            flashQuant: app.selectedFlashQuant,
            ctx: app.effectiveCtx(ramGiB: ramGiB),
            wiredLimitMB: effectiveWiredLimitMB(ramGiB: ramGiB),
            sessions: app.concurrentSessions)
        guard case let .blocked(reason) = result else { return nil }
        return reason
    }

    /// Content height capped to the visible screen, so short screens still get a
    /// resizable window with a scrollbar instead of one taller than the display.
    private var windowHeight: CGFloat {
        let screenMax = (NSScreen.main?.visibleFrame.height ?? 1200) - 24
        return min(max(contentHeight, 320), screenMax)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("The Metal wired memory limit").font(.headline)
                if let blockedReason {
                    Text("This configuration cannot fit safely while leaving memory for macOS.")
                    machineSummary
                    Label(
                        "A Metal wired-limit change cannot make this configuration fit. Reduce context or concurrent sessions in Settings.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    Text(blockedReason).font(.callout).foregroundStyle(.secondary)
                } else {
                    wiredLimitInstructions
                }
            }
            .padding(16)
            .frame(width: 560, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                contentHeight = height
            }
        }
        .frame(width: 600, height: windowHeight)
        .onAppear { WindowChrome.windowOpened(title: "DS4 Metal Wired Limit Help") }
        .onDisappear { WindowChrome.windowClosed() }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    private var machineSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your machine right now").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                row("Unified memory", "~\(Int(ramGiB)) GiB")
                row(
                    "GPU wired limit",
                    "~\(effectiveWiredLimitMB(ramGiB: ramGiB) / 1024) GiB"
                        + (emulatedWiredLimitMB() != nil
                            ? " (emulated)"
                            : (currentWiredLimitMB() > 0 ? " (raised via sysctl)" : " (macOS default)")))
                row("This setup needs", requiredMemoryLabel)
            }
            .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder private var wiredLimitInstructions: some View {
        Text(
            "macOS only lets the GPU wire a limited share of unified memory. ds4 wires the whole model "
                + "(weights + every resident session's context + graph and persistent backend allocations shared across sessions) for the GPU, so if that working set exceeds the limit, macOS pages it "
                + "and the server hangs while memory pegs near 100%. DS4 Control blocks Start until the limit "
                + "is high enough — raise it once and you're set."
        )

        machineSummary

        Text("1 · Raise the limit (takes effect immediately)").font(.headline)
        codeBlock(sysctlCommand)
        Text(
            advisoryNote + " The value resets on every reboot — "
                + "if you ran this before and it hangs again now, a restart wiped it."
        )
        .font(.callout).foregroundStyle(.secondary)

        Text("2 · Keep it across reboots").font(.headline)
        Text(
            "Set the same value in /etc/sysctl.conf so macOS applies it at boot. "
                + "The command replaces any existing iogpu.wired_limit_mb setting:"
        )
        .font(.callout)
        codeBlock(persistCommand)
        Text(
            "Other settings in the file are preserved. To undo later: delete the "
                + "iogpu.wired_limit_mb line and run `sudo sysctl iogpu.wired_limit_mb=0`."
        )
        .font(.callout).foregroundStyle(.secondary)

        Text("3 · Verify").font(.headline)
        Text(
            "Run `sysctl iogpu.wired_limit_mb` — it should print \(advisoryMB). "
                + "The popup re-checks every couple of seconds, so Start un-blocks on its own "
                + "as soon as the limit is up. No app restart needed."
        )
        .font(.callout)
    }

    @ViewBuilder private func codeBlock(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copiedCommand == text ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copiedCommand = text
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if copiedCommand == text { copiedCommand = nil }
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}
