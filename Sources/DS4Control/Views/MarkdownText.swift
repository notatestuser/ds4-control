// Markdown renderer for chat bubbles, backed by Lakr233/MarkdownView (battle-tested in FlowDown).
// This is the ONLY file that imports the renderer — the dependency seam.
//
// We render through the library's raw AppKit `MarkdownTextView` wrapped in our own
// `MarkdownNSText` representable, NOT the library's SwiftUI `MarkdownView`. That wrapper sizes
// itself with a GeometryReader plus a `DispatchQueue.main.async` height binding, which schedules a
// fresh layout pass on every pass; inside our LazyVStack-in-ScrollView (with the 30 Hz bottom
// follow) the placement graph never converges → 100% main-thread spin in
// `LazySubviewPlacements.placeSubviews` (profiled). `MarkdownNSText` instead reports height
// synchronously from `sizeThatFits` — width in, height out, in the same layout pass, no async
// binding — so layout converges in one pass. Selection, code highlighting, tables and math are
// still handled inside `MarkdownTextView`.

import AppKit
import Combine
import MarkdownParser
import MarkdownView
import SwiftUI

/// Renders a complete (non-streaming) markdown string. Used for finished assistant bubbles and the
/// thinking disclosure.
struct MarkdownText: View {
    let source: String

    init(_ source: String) { self.source = source }

    var body: some View {
        // `.default` theme: its colors are `NSColor.labelColor` / system dynamic colors, so it
        // tracks light/dark automatically — no explicit colorScheme plumbing needed.
        MarkdownNSText(markdown: Self.preprocess(source))
    }

    /// LaTeX cleanup + tag stripping applied before handing markdown to the renderer. Pure and
    /// renderer-agnostic.
    static func preprocess(_ s: String) -> String {
        stripTaggedBlocks(deLaTeXed(s))
    }

    /// Light LaTeX cleanup so the model's math reads as text rather than raw source. DeepSeek
    /// wraps math in \[ \] \( \) $$, boxes answers with \boxed{…}, and uses a few macros. This
    /// strips wrappers and maps common symbols — not a TeX engine; unknown macros pass through.
    static func deLaTeXed(_ s: String) -> String {
        var t = s
        for d in ["\\[", "\\]", "\\(", "\\)", "$$"] { t = t.replacingOccurrences(of: d, with: "") }
        t = t.replacingOccurrences(
            of: #"\\boxed\s*\{([^{}]*)\}"#, with: "**$1**", options: .regularExpression)
        t = t.replacingOccurrences(
            of: #"\\text\s*\{([^{}]*)\}"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(
            of: #"\\frac\s*\{([^{}]*)\}\s*\{([^{}]*)\}"#, with: "$1/$2", options: .regularExpression)
        let symbols: [(String, String)] = [
            ("times", "×"), ("cdots", "⋯"), ("cdot", "·"), ("div", "÷"), ("pm", "±"),
            ("leq", "≤"), ("geq", "≥"), ("neq", "≠"), ("approx", "≈"), ("equiv", "≡"),
            ("infty", "∞"), ("rightarrow", "→"), ("Rightarrow", "⇒"), ("to", "→"),
            ("ldots", "…"), ("sqrt", "√"), ("pi", "π"), ("theta", "θ"), ("alpha", "α"),
            ("beta", "β"), ("sum", "∑"),
        ]
        for (name, sym) in symbols {
            t = t.replacingOccurrences(
                of: "\\\\" + name + "(?![A-Za-z])", with: sym, options: .regularExpression)
        }
        return t
    }

    // Tag blocks removed from answer content: tool plumbing, and reasoning tags (reasoning
    // arrives separately via reasoning_content → ChatMessage.thinking and renders in the
    // disclosure, so inline <thinking>/<think> in content is redundant).
    private static let strippedTags: Set<String> = [
        "tool_call", "tool_response", "tool_result", "thinking", "think",
    ]

    /// Drop whole `<tag>…</tag>` blocks for tags in `strippedTags` — both multi-line blocks
    /// (open tag line … close tag line) and a single line that opens and closes inline. Tags
    /// are only recognized when the line *starts* with the tag, which is how the server emits
    /// them; unrelated `<` text in prose is left untouched. An unterminated block (e.g. mid-
    /// stream) stays hidden until it closes.
    static func stripTaggedBlocks(_ s: String) -> String {
        var out: [String] = []
        var lines = s.components(separatedBy: .newlines)[...]
        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("<"), let tag = extractOpeningTag(trimmed),
                strippedTags.contains(tag)
            else {
                out.append(line)
                continue
            }
            if trimmed.contains("</\(tag)>") { continue }  // inline open+close → drop this line only
            while let next = lines.first,
                extractClosingTag(next.trimmingCharacters(in: .whitespaces)) != tag
            {
                lines = lines.dropFirst()
            }
            lines = lines.dropFirst()  // consume the closing tag line (no-op at EOF)
        }
        return out.joined(separator: "\n")
    }

    private static func extractOpeningTag(_ s: String) -> String? {
        guard s.hasPrefix("<"), !s.hasPrefix("</"), s.hasSuffix(">") else { return nil }
        let name = s.dropFirst().dropLast().prefix { $0.isLetter || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }

    private static func extractClosingTag(_ s: String) -> String? {
        guard s.hasPrefix("</"), s.hasSuffix(">") else { return nil }
        let name = s.dropFirst(2).dropLast().prefix { $0.isLetter || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }
}

extension MarkdownText {
    /// Debug-only smoke test for the SwiftPM resource-bundle load path — the one that crashed the
    /// shipped .app when Highlightr's/SwiftMath's bundles weren't resolvable (`Bundle.module`
    /// `fatalError`). Building a code block + math forces Highlightr and SwiftMath to load their
    /// resource bundles. Gated by `DS4_SELFTEST_MARKDOWN=1` so it's inert in normal use; build.sh/CI
    /// runs the packaged binary with the env set to verify the bundles resolve before shipping.
    @MainActor static func runResourceSelfTestIfRequested() {
        guard ProcessInfo.processInfo.environment["DS4_SELFTEST_MARKDOWN"] == "1" else { return }
        _ = NSApplication.shared  // math rendering reads NSApp.effectiveAppearance; set NSApp first
        let md = "```swift\nlet x = 1\n```\n\nInline math: $x^2 + 1$\n"
        _ = MarkdownTextView.PreprocessedContent(parserResult: MarkdownParser().parse(md), theme: .default)
        FileHandle.standardError.write(Data("DS4_SELFTEST_MARKDOWN: OK\n".utf8))
        exit(0)
    }
}

/// Renders a streaming markdown string.
///
/// `ChatViewModel` already throttles published streaming mutations with a single-in-flight
/// cooldown, so this view must stay a pure function of `source`. A previous view-local timer copied
/// `source` into `@State`; when that tick landed during scroll/layout, SwiftUI logged "Publishing
/// changes from within view updates" and could spin AttributeGraph.
struct StreamingMarkdownText: View {
    let source: String

    init(_ source: String) {
        self.source = source
    }

    var body: some View {
        MarkdownNSText(markdown: MarkdownText.preprocess(source))
    }
}

/// Renders one preprocessed markdown string through the library's raw AppKit `MarkdownTextView`,
/// reporting its height **synchronously** for the proposed width via `sizeThatFits`. This is the
/// freeze-safe sizing contract: SwiftUI proposes a width, we return the matching height in the same
/// layout pass — a pure function of (width, content), no GeometryReader and no async height binding,
/// so the layout graph converges instead of re-scheduling itself (the cause of the profiled
/// `placeSubviews` spin). `boundingSize(for:)` is cached by Litext per width, so the repeated calls
/// SwiftUI makes while scrolling are cheap.
private struct MarkdownNSText: NSViewRepresentable {
    let markdown: String

    func makeNSView(context _: Context) -> MarkdownTextView {
        let view = MarkdownTextView()
        view.theme = .default
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: MarkdownTextView, context: Context) {
        guard context.coordinator.lastMarkdown != markdown else { return }
        context.coordinator.lastMarkdown = markdown
        let result = MarkdownParser().parse(markdown)
        let content = MarkdownTextView.PreprocessedContent(parserResult: result, theme: .default)
        view.setMarkdownManually(content)
        view.invalidateIntrinsicContentSize()
        context.coordinator.measuredWidth = -1  // content changed → next measure is real, not cached
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        // `boundingSize` → `LTXLabel.intrinsicContentSize` runs a full CoreText framesetter pass and
        // is NOT cached by the label; SwiftUI probes `sizeThatFits` many times per layout and the
        // 30 Hz bottom-follow re-lays-out constantly, so measuring on every call re-typesets the
        // whole document and pegs CoreText (profiled). Cache the height per width and re-measure only
        // when the streamed text changed (`measuredWidth` is reset in `updateNSView`); the frequent
        // scroll/probe re-layouts then cost nothing.
        let cache = context.coordinator
        if abs(cache.measuredWidth - width) < 0.5 {
            return CGSize(width: width, height: cache.measuredHeight)
        }
        let height = ceil(nsView.boundingSize(for: width).height)
        cache.measuredWidth = width
        cache.measuredHeight = height
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        var lastMarkdown = ""
        var measuredWidth: CGFloat = -1
        var measuredHeight: CGFloat = 0
    }
}
