import AppKit
import SwiftUI

/// Menu-bar label: the bundled "DS" vector wordmark (Resources/MenuBarDS.svg), drawn to
/// match SupaCode's MenuBarSC — Helvetica Bold outlines, per-glyph squeeze (D 0.78, S
/// 0.832), 450-unit cap+overshoot, 79.8-unit ink gap, their crop margins. Rendered as a
/// template image (adaptive monochrome at idle, like theirs); the tint carries the server
/// state, replacing the old per-state SF Symbol bolt.
struct MenuBarLabelView: View {
    let state: ServerState

    var body: some View {
        Image(nsImage: Self.wordmark)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxHeight: .infinity)
            .foregroundStyle(color)
    }

    /// Loaded once from the bundled SVG (white ink — template rendering uses only its
    /// alpha, like SupaCode's MenuBarSC asset). The declared size must be scaled to menu
    /// bar points — the SVG's native units are ~840×818, which would render gigantic.
    private static let wordmark: NSImage = {
        guard let url = Bundle.module.url(forResource: "MenuBarDS", withExtension: "svg"),
            let data = try? Data(contentsOf: url),
            let img = NSImage(data: data)
        else {
            preconditionFailure("MenuBarDS.svg missing from the resource bundle")
        }
        // SupaCode's MenuBarSC is 23.29×22 pt; our viewBox is 840.84×818.19 units.
        let scale = 22.0 / 818.19
        img.size = NSSize(width: 840.84 * scale, height: 22)
        img.isTemplate = true
        return img
    }()

    /// Adaptive monochrome at idle (SupaCode's template look); the busy states keep the
    /// old bolt's colors.
    private var color: Color {
        if case .error = state { return .red }
        switch state {
        case .ready: return .green
        case .starting, .downloading: return .orange
        default: return .primary
        }
    }
}
