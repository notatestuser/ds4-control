// Ported from mlx-serve (MIT, Copyright 2026 David):
// app/Sources/MLXServe/Views/ChatView.swift — MarkdownText, SelectableMarkdownNSText,
// IntrinsicTextView. Selectable NSTextView markdown renderer (code blocks, lists,
// headings, bold/italic/inline-code, GFM + ASCII tables, model-tag cards). Logic is
// verbatim from the source; only the unused renderModelTagBody helper was dropped to
// keep the file standalone. Pure Apple stdlib — no third-party dependency.

import AppKit
import SwiftUI

struct MarkdownText: View {
    let source: String

    init(_ source: String) {
        self.source = Self.deLaTeXed(source)
    }

    var body: some View {
        SelectableMarkdownNSText(attributed: Self.attributedString(for: source))
    }

    /// Light LaTeX cleanup so the model's math answers read as text rather than raw source.
    /// DeepSeek wraps math in display/inline delimiters (\[ \], \( \), $$), boxes final answers
    /// with \boxed{…}, and sprinkles a few macros. This strips the wrappers and maps the common
    /// symbols — it is not a TeX engine; uncommon macros pass through untouched.
    static func deLaTeXed(_ s: String) -> String {
        var t = s
        for d in ["\\[", "\\]", "\\(", "\\)", "$$"] { t = t.replacingOccurrences(of: d, with: "") }
        t = t.replacingOccurrences(of: #"\\boxed\s*\{([^{}]*)\}"#, with: "**$1**", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\\text\s*\{([^{}]*)\}"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\\frac\s*\{([^{}]*)\}\s*\{([^{}]*)\}"#, with: "$1/$2", options: .regularExpression)
        // name → glyph. Listed longest-prefix first (cdots before cdot); the (?![A-Za-z])
        // lookahead stops a short macro matching inside a longer one (\le vs \leq).
        let symbols: [(String, String)] = [
            ("times", "×"), ("cdots", "⋯"), ("cdot", "·"), ("div", "÷"), ("pm", "±"),
            ("leq", "≤"), ("geq", "≥"), ("neq", "≠"), ("approx", "≈"), ("equiv", "≡"),
            ("infty", "∞"), ("rightarrow", "→"), ("Rightarrow", "⇒"), ("to", "→"),
            ("ldots", "…"), ("sqrt", "√"), ("pi", "π"), ("theta", "θ"), ("alpha", "α"),
            ("beta", "β"), ("sum", "∑"),
        ]
        for (name, sym) in symbols {
            t = t.replacingOccurrences(of: "\\\\" + name + "(?![A-Za-z])", with: sym, options: .regularExpression)
        }
        return t
    }

    // Tags whose entire block (including the tag lines) we render as a styled "card".
    private static let modelTags: Set<String> = [
        "plan", "thinking", "think", "scratchpad", "reflection",
    ]

    // Tags we hide entirely (rare; e.g. tool plumbing leaking into text).
    private static let hiddenTags: Set<String> = [
        "tool_call", "tool_response", "tool_result",
    ]

    // Golden-ratio rhythm. Heading sizes form a modular scale (each level = body·φ^(n/3),
    // so H1 = body·φ), and the space above a heading exceeds the space below it in φ
    // proportion (8:5 — consecutive Fibonacci ≈ 1.618), so a heading binds to the text
    // it introduces rather than floating between sections.
    private static let phi = 1.618
    private static let baseBlockSpace: CGFloat = 4  // gap between ordinary blocks (unchanged)
    private static let headingSpaceBelow: CGFloat = 5  // heading → its content (tight)
    private static let headingSpaceAbove: CGFloat = 8  // previous block → heading (≈ below·φ)

    private enum Block {
        case paragraph(String)
        case code(language: String?, body: String)
        case heading(level: Int, text: String)
        case bulletList([String])
        case numberedList([(String, String)])
        case table(ParsedTable)
        case modelTag(name: String, body: String)
    }

    private enum TableAlignment {
        case leading, center, trailing
    }

    private struct ParsedTable {
        var headers: [String]
        var alignments: [TableAlignment]
        var rows: [[String]]
    }

    private static func parseBlocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var lines = text.components(separatedBy: .newlines)[...]

        func flushParagraph(_ buffer: inout [String]) {
            if !buffer.isEmpty {
                blocks.append(.paragraph(buffer.joined(separator: "\n")))
                buffer.removeAll()
            }
        }

        var paragraphBuffer: [String] = []

        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if trimmed.hasPrefix("```") {
                flushParagraph(&paragraphBuffer)
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                while let next = lines.first, !next.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(next)
                    lines = lines.dropFirst()
                }
                lines = lines.dropFirst()  // consume closing ```
                blocks.append(.code(language: language.isEmpty ? nil : language, body: body.joined(separator: "\n")))
                continue
            }

            // Heading (CommonMark: 1–6 leading #'s; 7+ is a paragraph)
            if let hashRange = trimmed.range(of: "^#{1,6} ", options: .regularExpression) {
                flushParagraph(&paragraphBuffer)
                let level = trimmed.distance(from: trimmed.startIndex, to: hashRange.upperBound) - 1
                let text = String(trimmed[hashRange.upperBound...])
                blocks.append(.heading(level: level, text: text))
                continue
            }

            // Bullet list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph(&paragraphBuffer)
                var items: [String] = [String(trimmed.dropFirst(2))]
                while let next = lines.first {
                    let nt = next.trimmingCharacters(in: .whitespaces)
                    if nt.hasPrefix("- ") || nt.hasPrefix("* ") {
                        items.append(String(nt.dropFirst(2)))
                        lines = lines.dropFirst()
                    } else {
                        break
                    }
                }
                blocks.append(.bulletList(items))
                continue
            }

            // Numbered list
            if let match = trimmed.range(of: "^\\d+\\. ", options: .regularExpression) {
                flushParagraph(&paragraphBuffer)
                var items: [(String, String)] = []
                let marker = String(trimmed[..<match.upperBound]).trimmingCharacters(in: .whitespaces)
                items.append((marker, String(trimmed[match.upperBound...])))
                while let next = lines.first {
                    let nt = next.trimmingCharacters(in: .whitespaces)
                    if let m = nt.range(of: "^\\d+\\. ", options: .regularExpression) {
                        let mk = String(nt[..<m.upperBound]).trimmingCharacters(in: .whitespaces)
                        items.append((mk, String(nt[m.upperBound...])))
                        lines = lines.dropFirst()
                    } else {
                        break
                    }
                }
                blocks.append(.numberedList(items))
                continue
            }

            // Table (GFM)
            if let (table, consumed) = Self.tryParseTable(line, rest: lines) {
                flushParagraph(&paragraphBuffer)
                blocks.append(.table(table))
                lines = Array(lines.dropFirst(consumed))[...]
                continue
            }

            // ASCII pseudo-table
            if let (table, consumed) = Self.tryParseAsciiPseudoTable(line, rest: lines) {
                flushParagraph(&paragraphBuffer)
                blocks.append(.table(table))
                lines = Array(lines.dropFirst(consumed))[...]
                continue
            }

            // Model tag block (e.g. <plan> ... </plan>)
            if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"),
                let tagName = Self.extractOpeningTag(trimmed),
                Self.modelTags.contains(tagName)
            {
                flushParagraph(&paragraphBuffer)
                var body: [String] = []
                while let next = lines.first,
                    Self.extractClosingTag(next.trimmingCharacters(in: .whitespaces)) != tagName
                {
                    body.append(next)
                    lines = lines.dropFirst()
                }
                lines = lines.dropFirst()  // consume closing tag
                blocks.append(.modelTag(name: tagName, body: body.joined(separator: "\n")))
                continue
            }

            // Hidden tag block
            if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"),
                let tagName = Self.extractOpeningTag(trimmed),
                Self.hiddenTags.contains(tagName)
            {
                flushParagraph(&paragraphBuffer)
                while let next = lines.first,
                    Self.extractClosingTag(next.trimmingCharacters(in: .whitespaces)) != tagName
                {
                    lines = lines.dropFirst()
                }
                lines = lines.dropFirst()
                continue
            }

            // Plain paragraph line
            paragraphBuffer.append(line)
            continue
        }
        flushParagraph(&paragraphBuffer)
        return blocks
    }

    private static func tryParseTable(_ first: String, rest: ArraySlice<String>) -> (ParsedTable, Int)? {
        let firstTrimmed = first.trimmingCharacters(in: .whitespaces)
        guard firstTrimmed.contains("|") else { return nil }
        guard let separatorLine = rest.first else { return nil }
        guard Self.isTableSeparator(separatorLine) else { return nil }

        let headers = Self.parseTableRow(firstTrimmed)
        let alignments = Self.parseTableAlignments(separatorLine)
        guard headers.count == alignments.count else { return nil }

        var rows: [[String]] = []
        var consumed = 1  // separator
        var remaining = rest.dropFirst()
        while let row = remaining.first {
            let rowTrimmed = row.trimmingCharacters(in: .whitespaces)
            guard rowTrimmed.contains("|"), !rowTrimmed.isEmpty else { break }
            rows.append(Self.parseTableRow(rowTrimmed))
            consumed += 1
            remaining = remaining.dropFirst()
        }
        return (ParsedTable(headers: headers, alignments: alignments, rows: rows), consumed)
    }

    private static func tryParseAsciiPseudoTable(_ first: String, rest: ArraySlice<String>) -> (ParsedTable, Int)? {
        // Detect two-or-more space-separated columns across >= 2 consecutive lines.
        func splitColumns(_ s: String) -> [String] { Self.splitOnDoubleSpace(s) }
        let firstCols = splitColumns(first)
        guard firstCols.count >= 2 else { return nil }
        var consumed = 0
        var remaining = rest
        // include the first line
        var allLines: [String] = [first]
        while let next = remaining.first {
            if next.trimmingCharacters(in: .whitespaces).isEmpty { break }
            if Self.isAsciiRule(next) {
                consumed += 1
                remaining = remaining.dropFirst()
                continue
            }
            let cols = splitColumns(next)
            if cols.count < 2 { break }
            allLines.append(next)
            consumed += 1
            remaining = remaining.dropFirst()
        }
        guard allLines.count >= 2 else { return nil }
        let parsed = allLines.map { splitColumns($0) }
        let colCount = parsed.map(\.count).max() ?? 0
        let headers = parsed[0]
        let normalized = parsed.map { row -> [String] in
            var r = row
            while r.count < colCount { r.append("") }
            return r
        }
        let aligns = Array(repeating: TableAlignment.leading, count: colCount)
        return (
            ParsedTable(headers: headers, alignments: aligns, rows: Array(normalized.dropFirst())),
            consumed
        )
    }

    private static func splitOnDoubleSpace(_ s: String) -> [String] {
        // Split on runs of 2+ spaces, trimming each segment.
        s.components(separatedBy: "  ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func isAsciiRule(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        return t.allSatisfy { $0 == "-" || $0 == "=" || $0 == "+" || $0 == " " || $0 == "|" }
    }

    private static func parseTableRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s = String(s.dropFirst()) }
        if s.hasSuffix("|") { s = String(s.dropLast()) }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = Self.parseTableRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let t = cell.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return false }
            return t.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func parseTableAlignments(_ line: String) -> [TableAlignment] {
        Self.parseTableRow(line).map { cell in
            let t = cell.trimmingCharacters(in: .whitespaces)
            let left = t.hasPrefix(":")
            let right = t.hasSuffix(":")
            if left && right { return .center }
            if right { return .trailing }
            if left { return .leading }
            return .leading
        }
    }

    private static func extractOpeningTag(_ s: String) -> String? {
        guard s.hasPrefix("<"), !s.hasPrefix("</"), s.hasSuffix(">") else { return nil }
        let inner = s.dropFirst().dropLast()
        let name = inner.prefix { $0.isLetter || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }

    private static func extractClosingTag(_ s: String) -> String? {
        guard s.hasPrefix("</"), s.hasSuffix(">") else { return nil }
        let inner = s.dropFirst(2).dropLast()
        let name = inner.prefix { $0.isLetter || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }

    /// Bounded cache of completed message parses keyed by source string. Re-renders of the same
    /// content (e.g. scrolling back to a completed message after the streaming tail invalidates
    /// the transcript) skip the markdown re-parse. The streaming tail itself produces a new
    /// string per token, so it never hits this cache — that's covered upstream by the MessageBubble
    /// Equatable skip, not here.
    private static let attributedStringCache: NSCache<NSString, NSAttributedString> = {
        let c = NSCache<NSString, NSAttributedString>()
        c.countLimit = 32
        return c
    }()

    static func attributedString(for source: String) -> NSAttributedString {
        let key = source as NSString
        if let cached = attributedStringCache.object(forKey: key) {
            return cached
        }
        let result = NSMutableAttributedString()
        let blocks = parseBlocks(source)
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                result.append(blockSpacer(spacing(before: block, after: blocks[index - 1])))
            }
            switch block {
            case .paragraph(let text):
                result.append(renderInline(text))
            case .code(let language, let body):
                result.append(renderCode(language: language, body: body))
            case .heading(let level, let text):
                result.append(renderHeading(level: level, text: text))
            case .bulletList(let items):
                result.append(renderBulletList(items))
            case .numberedList(let items):
                result.append(renderNumberedList(items))
            case .table(let table):
                result.append(renderTable(table))
            case .modelTag(let name, let body):
                result.append(renderModelTag(name: name, body: body))
            }
        }
        attributedStringCache.setObject(result, forKey: key)
        return result
    }

    /// Golden-ratio vertical gap between two adjacent blocks: generous above a heading,
    /// tight below it (so the heading groups with its content), baseline otherwise.
    private static func spacing(before current: Block, after previous: Block) -> CGFloat {
        if case .heading = current { return headingSpaceAbove }
        if case .heading = previous { return headingSpaceBelow }
        return baseBlockSpace
    }

    private static func blockSpacer(_ size: CGFloat = baseBlockSpace) -> NSAttributedString {
        NSAttributedString(string: "\n\n", attributes: [.font: NSFont.systemFont(ofSize: size)])
    }

    private static func renderInline(_ text: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        let base = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        guard let attributed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(
                string: text,
                attributes: [.font: base, .foregroundColor: NSColor.labelColor]
            )
        }
        let ns = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        let full = NSRange(location: 0, length: ns.length)
        ns.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        ns.enumerateAttribute(.font, in: full) { value, range, _ in
            let existing = value as? NSFont
            let traits = existing.map { NSFontManager.shared.traits(of: $0) } ?? []
            var newFont = base
            if traits.contains(.boldFontMask) {
                newFont = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
            }
            if traits.contains(.italicFontMask) {
                newFont = NSFontManager.shared.convert(newFont, toHaveTrait: .italicFontMask)
            }
            ns.addAttribute(.font, value: newFont, range: range)
        }
        return ns
    }

    private static func renderCode(language: String?, body: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 12
        paragraph.headIndent = 12
        paragraph.tailIndent = -12
        paragraph.paragraphSpacingBefore = 6
        paragraph.paragraphSpacing = 6
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        return NSAttributedString(
            string: body,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.textBackgroundColor.blended(withFraction: 0.08, of: .gray)
                    ?? .textBackgroundColor,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private static func renderHeading(level: Int, text: String) -> NSAttributedString {
        // Modular scale anchored on the body size in equal golden steps (×φ^⅓ per level):
        // H1 = body·φ, H2 = body·φ^(2/3), H3 = body·φ^(1/3), H4 = body, and H5/H6 step
        // just below body (still bold) so the full 1–6 range stays distinct.
        let body = Double(NSFont.systemFontSize)
        let size = CGFloat((body * pow(phi, Double(4 - level) / 3.0)).rounded())
        let font = NSFont.systemFont(ofSize: size, weight: .bold)
        // Block-level spacing is owned by the golden-ratio spacers (see `spacing`); the
        // gentle line height just keeps the rare multi-line heading readable.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.1
        // Render inline markdown inside heading, then enforce heading font.
        let inline = NSMutableAttributedString(attributedString: renderInline(text))
        let full = NSRange(location: 0, length: inline.length)
        inline.addAttribute(.font, value: font, range: full)
        inline.addAttribute(.paragraphStyle, value: paragraph, range: full)
        return inline
    }

    private static func renderBulletList(_ items: [String]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = 16
        paragraph.firstLineHeadIndent = 0
        paragraph.paragraphSpacing = 2
        for (idx, item) in items.enumerated() {
            if idx > 0 { result.append(NSAttributedString(string: "\n")) }
            let bullet = NSAttributedString(
                string: "•  ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            let content = NSMutableAttributedString(attributedString: renderInline(item))
            let line = NSMutableAttributedString()
            line.append(bullet)
            line.append(content)
            line.addAttribute(
                .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
            result.append(line)
        }
        return result
    }

    private static func renderNumberedList(_ items: [(String, String)]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = 24
        paragraph.firstLineHeadIndent = 0
        paragraph.paragraphSpacing = 2
        for (idx, item) in items.enumerated() {
            if idx > 0 { result.append(NSAttributedString(string: "\n")) }
            let marker = NSAttributedString(
                string: "\(item.0)  ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            let content = NSMutableAttributedString(attributedString: renderInline(item.1))
            let line = NSMutableAttributedString()
            line.append(marker)
            line.append(content)
            line.addAttribute(
                .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
            result.append(line)
        }
        return result
    }

    private static func renderTable(_ table: ParsedTable) -> NSAttributedString {
        // Render as monospace aligned text for simplicity and reliable selection.
        let allRows = [table.headers] + table.rows
        let colCount = table.headers.count
        var widths = Array(repeating: 0, count: colCount)
        for row in allRows {
            for (i, cell) in row.enumerated() where i < colCount {
                widths[i] = max(widths[i], cell.count)
            }
        }
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        let result = NSMutableAttributedString()
        func renderRow(_ cells: [String], bold: Bool) -> NSAttributedString {
            var parts: [String] = []
            for i in 0..<colCount {
                let cell = i < cells.count ? cells[i] : ""
                let padded = cell.padding(toLength: widths[i], withPad: " ", startingAt: 0)
                parts.append(padded)
            }
            let rowString = parts.joined(separator: "  ")
            let f =
                bold ? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .bold) : font
            return NSAttributedString(
                string: rowString,
                attributes: [.font: f, .foregroundColor: NSColor.labelColor]
            )
        }
        result.append(renderRow(table.headers, bold: true))
        for row in table.rows {
            result.append(NSAttributedString(string: "\n"))
            result.append(renderRow(row, bold: false))
        }
        return result
    }

    private static func renderModelTag(name: String, body: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 10
        paragraph.headIndent = 10
        paragraph.tailIndent = -10
        paragraph.paragraphSpacingBefore = 6
        paragraph.paragraphSpacing = 6
        let title = NSMutableAttributedString(
            string: "\(name.capitalized)\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize - 1, weight: .semibold),
                .foregroundColor: NSColor.systemPurple,
                .paragraphStyle: paragraph,
            ]
        )
        let bodyAttr = NSMutableAttributedString(attributedString: renderInline(body))
        bodyAttr.addAttribute(
            .paragraphStyle, value: paragraph,
            range: NSRange(location: 0, length: bodyAttr.length))
        bodyAttr.addAttribute(
            .foregroundColor, value: NSColor.secondaryLabelColor,
            range: NSRange(location: 0, length: bodyAttr.length))
        title.append(bodyAttr)
        return title
    }
}

struct SelectableMarkdownNSText: NSViewRepresentable {
    let attributed: NSAttributedString

    func makeNSView(context: Context) -> IntrinsicTextView {
        let textView = IntrinsicTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textColor = .labelColor
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.textStorage?.setAttributedString(attributed)
        return textView
    }

    func updateNSView(_ nsView: IntrinsicTextView, context: Context) {
        // Only mutate the storage if the assistant's content actually changed.
        // Streaming chunks call updateNSView many times per second; an unconditional
        // replace would interrupt an active selection on every frame.
        if nsView.textStorage?.isEqual(to: attributed) == false {
            nsView.textStorage?.setAttributedString(attributed)
            nsView.invalidateIntrinsicContentSize()
        }
    }
}

/// NSTextView that reports its laid-out height as its intrinsic content size, so embedding
/// it in SwiftUI's layout system "just works" — no manual height binding required.
///
/// `setFrameSize` triggers an invalidation so a width reflow (e.g. the parent re-flows after
/// a neighbour's width change) re-reports the new height; `didChangeText` does the same after
/// `textStorage` is replaced. Both together are the proven mlx-serve path: intrinsicContentSize
/// is read off the current laid-out state, and SwiftUI picks that height up on the next pass.
final class IntrinsicTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else {
            return super.intrinsicContentSize
        }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height))
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Width changes (parent re-flow) require a layout-driven height re-check.
        invalidateIntrinsicContentSize()
    }
}
