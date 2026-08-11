import SwiftUI

/// Walkthrough window for the Metal wired memory limit: why the gate fired, the exact
/// sysctl to fix it, and how to make it survive reboots (the sysctl resets on every
/// restart — the classic "it worked before, now it hangs" trap). Opened from the popup's
/// gated-Start note.
struct WiredLimitHelpView: View {
    @EnvironmentObject var app: AppState
    private let ramGiB = systemRamGiB()
    @State private var copied: String?
    /// Measured content height — the window opens tall enough to show everything at once.
    @State private var contentHeight: CGFloat = 0

    private var advisoryMB: Int { wiredLimitAdvisoryMB(ramGiB: ramGiB) }
    private var sysctlCommand: String { "sudo sysctl iogpu.wired_limit_mb=\(advisoryMB)" }
    private var persistCommand: String { "echo 'iogpu.wired_limit_mb=\(advisoryMB)' | sudo tee -a /etc/sysctl.conf" }

    private var requiredMB: Int {
        requiredWiredMB(
            variant: app.selectedVariant, flashQuant: app.selectedFlashQuant,
            ctx: app.effectiveCtx(ramGiB: ramGiB), kvDiskCache: app.kvDiskCache)
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
                Text(
                    "macOS only lets the GPU wire a limited share of unified memory. ds4 wires the whole model "
                        + "(weights + context) for the GPU, so if that working set exceeds the limit, macOS pages it "
                        + "and the server hangs while memory pegs near 100%. DS4 Control blocks Start until the limit "
                        + "is high enough — raise it once and you're set."
                )

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
                        row("This setup needs", "~\(requiredMB / 1024) GiB")
                    }
                    .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }

                Text("1 · Raise the limit (takes effect immediately)").font(.headline)
                codeBlock(sysctlCommand, id: "raise")
                Text(
                    "\(advisoryMB) MB leaves ~8 GiB for macOS. The value resets on every reboot — "
                        + "if you ran this before and it hangs again now, a restart wiped it."
                )
                .font(.callout).foregroundStyle(.secondary)

                Text("2 · Keep it across reboots").font(.headline)
                Text(
                    "Add the same value to /etc/sysctl.conf so macOS applies it at boot:"
                )
                .font(.callout)
                codeBlock(persistCommand, id: "persist")
                Text(
                    "Check what's already in the file first with `cat /etc/sysctl.conf` — if an "
                        + "iogpu.wired_limit_mb line exists, edit that one instead of adding another. "
                        + "To undo later: delete the line and run `sudo sysctl iogpu.wired_limit_mb=0`."
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

    @ViewBuilder private func codeBlock(_ text: String, id: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied == id ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = id
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if copied == id { copied = nil }
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}
