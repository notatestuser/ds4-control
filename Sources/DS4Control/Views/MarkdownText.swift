// Selectable markdown renderer for chat bubbles, backed by Textual (pure SwiftUI).
// Replaces the former NSTextView stack (SelectableMarkdownNSText / IntrinsicTextView):
// going pure-SwiftUI removes the NSView width↔height self-sizing loop that caused the chat
// freeze. This is the ONLY file that imports Textual — the dependency seam.

import SwiftUI
import Textual

/// Renders a complete (non-streaming) markdown string as one Textual document: one parse,
/// correct inter-block spacing, whole-message text selection. Used for finished assistant
/// bubbles and the thinking disclosure.
struct MarkdownText: View {
    let source: String

    init(_ source: String) { self.source = source }

    var body: some View {
        StructuredText(markdown: Self.preprocess(source))
            .ds4MarkdownStyle()
    }

    /// LaTeX cleanup + tag stripping applied before handing markdown to Textual. Pure and
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

/// Renders a streaming markdown string incrementally: completed blocks are frozen via
/// `.equatable()` (SwiftUI skips re-rendering a block whose text is unchanged), and only the
/// trailing incomplete block re-parses per tick. Bounds per-tick cost to O(tail).
struct StreamingMarkdownText: View {
    let source: String

    /// Gap between block views; tuned to match `MarkdownText`'s single-view inter-block
    /// spacing so there is no visual "settle" when the bubble collapses on finalize (Task 6).
    private static let blockSpacing: CGFloat = 8

    init(_ source: String) { self.source = source }

    var body: some View {
        let parts = MarkdownBlocks.splitBlocks(source)
        VStack(alignment: .leading, spacing: Self.blockSpacing) {
            ForEach(Array(parts.completed.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(markdown: block).equatable()
            }
            if !parts.tail.isEmpty {
                MarkdownBlockView(markdown: parts.tail)
            }
        }
    }
}

/// One markdown block rendered via Textual. `Equatable` on its source so SwiftUI skips
/// re-rendering frozen (completed) blocks while later blocks stream.
private struct MarkdownBlockView: View, Equatable {
    let markdown: String

    nonisolated static func == (a: MarkdownBlockView, b: MarkdownBlockView) -> Bool {
        a.markdown == b.markdown
    }

    var body: some View {
        StructuredText(markdown: MarkdownText.preprocess(markdown))
            .ds4MarkdownStyle()
    }
}

extension View {
    /// The DS4 markdown look: Textual's `.gitHub` style — whose colors are `DynamicColor`
    /// light/dark pairs, so it tracks the system appearance via the SwiftUI `colorScheme`.
    ///
    /// Textual's native text selection (`.textual.textSelection(.enabled)`) is intentionally
    /// omitted: its AppKit selection overlay (`AppKitTextSelectionView` + per-fragment
    /// `GeometryReader`s + `@Environment` keypath/metadata resolution) pegs the main thread when
    /// scrolling a transcript of many bubbles — a profiled 100% main-thread AttributeGraph storm.
    /// Copy stays available through the bubble's context menu ("Copy Message"). Note: SwiftUI's own
    /// `.textSelection(.enabled)` is NOT a workaround — Textual reads SwiftUI's `textSelectability`
    /// environment and activates the same overlay (re-profiled: identical scroll freeze).
    fileprivate func ds4MarkdownStyle() -> some View {
        self
            .textual.structuredTextStyle(.gitHub)
    }
}
