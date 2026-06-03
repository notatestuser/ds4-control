// Chat UI ported from mlx-serve (MIT, Copyright 2026 David):
// app/Sources/MLXServe/Views/ChatView.swift. The transcript layout, auto-scroll to
// the latest message, MessageBubble and the iMessage-style input bar are adapted from
// that source, stripped of mlx-serve's agent/tools/MCP/multi-session machinery for
// DS4's single conversation. GeneratingIndicator is fresh DS4 code (the original drove
// IOKit/Mach GPU telemetry on a polling Timer, unsuitable here).

import AppKit
import Combine
import SwiftUI

struct ChatView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var supervisor: SupervisorService
    @ObservedObject var viewModel: ChatViewModel

    @FocusState private var inputFocused: Bool

    /// How many of the most recent messages stay in the active view tree. Older
    /// messages are *frozen* — excluded from the `ForEach` so the layout pass
    /// doesn't measure them on every streaming token. The chat freeze samples
    /// showed the layout pass iterating every message on every render; with a
    /// window of 50 the per-token work is bounded to 50 measurements regardless
    /// of total transcript length. A "Show earlier" button at the top of the
    /// list grows the window backward when the user wants to scroll back.
    private static let transcriptWindowSize = 50

    @State private var bottomSnapRequest = 0

    /// Extra older messages the user has explicitly expanded into the window via
    /// the "Show earlier" button. Reset to 0 on `clear` (handled by the
    /// `onChange` of `messages.count` — if the user clears, the window starts
    /// fresh; if they keep chatting, the window keeps whatever they've loaded).
    @State private var transcriptExtraAbove = 0

    /// Imperative scroll-follow bookkeeping. These values do not render UI, so they must not be
    /// SwiftUI-publishing state: scroll geometry callbacks can run during layout, and publishing
    /// from there dirties AttributeGraph while it is already placing the transcript.
    @State private var scrollCoordinator = ScrollCoordinator()

    /// Scroll metrics observed (via `onScrollGeometryChange`) to drive the follow guard.
    private struct ScrollMetrics: Equatable {
        var offsetY: CGFloat
        var distanceFromBottom: CGFloat
    }

    private struct StreamingTailRevision: Equatable {
        var messageID: UUID?
        var messageCount: Int
        var snapRequest: Int
        var contentLength: Int
        var thinkingLength: Int

        var isActive: Bool { messageID != nil }

        static let inactive = StreamingTailRevision(
            messageID: nil,
            messageCount: 0,
            snapRequest: 0,
            contentLength: 0,
            thinkingLength: 0)
    }

    private final class ScrollCoordinator {
        var userPinnedToBottom = true
    }

    private struct BottomScrollDriver: NSViewRepresentable {
        let shouldFollow: Bool
        let revision: StreamingTailRevision

        func makeNSView(context _: Context) -> NSView {
            let view = NSView(frame: .zero)
            view.setContentHuggingPriority(.required, for: .vertical)
            view.setContentCompressionResistancePriority(.required, for: .vertical)
            return view
        }

        func updateNSView(_ view: NSView, context: Context) {
            let snapRequested = context.coordinator.lastRevision.snapRequest != revision.snapRequest
            guard shouldFollow || snapRequested else {
                context.coordinator.lastRevision = revision
                return
            }

            let rowCountChanged = context.coordinator.lastRevision.messageCount != revision.messageCount
            let changed = context.coordinator.lastRevision != revision || !context.coordinator.didInitialScroll
            context.coordinator.lastRevision = revision
            context.coordinator.didInitialScroll = true
            guard changed, !context.coordinator.scrollScheduled else { return }

            context.coordinator.scrollScheduled = true
            DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
                coordinator?.scrollScheduled = false
                guard let view else { return }
                Self.scrollTranscriptToBottom(from: view)
            }
            if rowCountChanged {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak view] in
                    guard let view else { return }
                    Self.scrollTranscriptToBottom(from: view)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak view] in
                    guard let view else { return }
                    Self.scrollTranscriptToBottom(from: view)
                }
            }
        }

        private static func scrollTranscriptToBottom(from view: NSView) {
            guard let scrollView = findTranscriptScrollView(from: view),
                let documentView = scrollView.documentView
            else { return }

            scrollView.layoutSubtreeIfNeeded()
            documentView.layoutSubtreeIfNeeded()

            let bottomY = max(0, documentView.frame.height - scrollView.contentView.bounds.height)
            let point = NSPoint(x: scrollView.contentView.bounds.origin.x, y: bottomY)
            scrollView.contentView.scroll(to: point)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private static func findTranscriptScrollView(from view: NSView) -> NSScrollView? {
            if let enclosing = view.enclosingScrollView { return enclosing }

            var current: NSView? = view
            while let candidate = current {
                if let scrollView = findLargestVerticalScrollView(in: candidate) {
                    return scrollView
                }
                current = candidate.superview
            }

            guard let contentView = view.window?.contentView else { return nil }
            return findLargestVerticalScrollView(in: contentView)
        }

        private static func findLargestVerticalScrollView(in root: NSView) -> NSScrollView? {
            var best: NSScrollView?
            var bestArea: CGFloat = 0

            func visit(_ view: NSView) {
                if let scrollView = view as? NSScrollView,
                    let documentView = scrollView.documentView
                {
                    let scrollableHeight = documentView.frame.height - scrollView.contentView.bounds.height
                    let area = scrollView.bounds.width * scrollView.bounds.height
                    if scrollableHeight > 1, area > bestArea {
                        best = scrollView
                        bestArea = area
                    }
                }

                for subview in view.subviews {
                    visit(subview)
                }
            }

            visit(root)
            return best
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        final class Coordinator {
            var lastRevision = StreamingTailRevision.inactive
            var didInitialScroll = false
            var scrollScheduled = false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            inputBar
            Divider()
            statusBar
        }
        .frame(minWidth: 560, minHeight: 640)
        .onAppear { WindowChrome.windowOpened(title: "DS4 Chat") }
        .onDisappear { WindowChrome.windowClosed() }
        // Focus the input the instant the window becomes key. WindowChrome makes it key
        // asynchronously (after the accessory→regular switch), so the old fixed 0.3s delay
        // was racy — this fires exactly on the key transition, every open.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
            note in
            if (note.object as? NSWindow)?.title == "DS4 Chat" { inputFocused = true }
        }
    }

    /// Bottom status bar: context window usage (used / total) with a thin bar.
    private var statusBar: some View {
        HStack(spacing: 8) {
            Text("Context")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(
                value: Double(min(viewModel.contextUsedTokens, supervisor.ctx)),
                total: Double(max(supervisor.ctx, 1))
            )
            .progressViewStyle(.linear)
            .frame(width: 120)
            Text("\(viewModel.contextUsedTokens.formatted()) / \(supervisor.ctx.formatted())")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Toggle("Max Think", isOn: $app.thinkMaxChat)
                .toggleStyle(.checkbox)
                .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var header: some View {
        HStack {
            Text(supervisor.activeModel ?? viewModel.model)
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()
            Button("Clear") {
                viewModel.clear()
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.messages.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var transcript: some View {
        List {
            let window = transcriptWindow()
            let hiddenAbove = viewModel.messages.count - window.count
            if hiddenAbove > 0 {
                // "Show earlier" affordance — tap to grow the window backward by another
                // `transcriptWindowSize`. The system list keeps rows outside the viewport
                // virtualized, so expanded history is not fully materialized during streaming.
                Button {
                    transcriptExtraAbove += min(hiddenAbove, Self.transcriptWindowSize)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.circle")
                        Text(
                            "Show \(min(hiddenAbove, Self.transcriptWindowSize)) earlier message\(hiddenAbove == 1 ? "" : "s")"
                        )
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
                    .background(Color(.controlBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            ForEach(window) { message in
                MessageBubble(message: message)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            if viewModel.isStreaming && !viewModel.hasReceivedFirstToken {
                HStack {
                    GeneratingIndicator()
                    Spacer()
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay(alignment: .bottom) {
            BottomScrollDriver(
                shouldFollow: scrollCoordinator.userPinnedToBottom,
                revision: streamingTailRevision
            )
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
        }
        .onChange(of: viewModel.messages.count) { _, _ in
            scrollCoordinator.userPinnedToBottom = true
        }
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(
                offsetY: geometry.contentOffset.y,
                distanceFromBottom: geometry.contentSize.height - geometry.visibleRect.maxY)
        } action: { old, new in
            // Disengage the follow only on a deliberate scroll-up — the offset *decreases*.
            // Streaming growth pushes the bottom away (distance grows) but leaves the offset
            // unchanged, so it must NOT unpin. Re-engage once the view is back at the bottom.
            if new.offsetY < old.offsetY - 40 {
                scrollCoordinator.userPinnedToBottom = false
            } else if new.distanceFromBottom < 24 {
                scrollCoordinator.userPinnedToBottom = true
            }
        }
    }

    private var streamingTailRevision: StreamingTailRevision {
        guard viewModel.isStreaming,
            let message = viewModel.messages.last,
            message.isStreaming
        else { return .inactive }

        return StreamingTailRevision(
            messageID: message.id,
            messageCount: viewModel.messages.count,
            snapRequest: bottomSnapRequest,
            contentLength: message.content.utf8.count,
            thinkingLength: message.thinking.utf8.count)
    }

    private func submitMessage() {
        guard supervisor.state == .ready, viewModel.canSend else { return }
        scrollCoordinator.userPinnedToBottom = true
        viewModel.send()
        bottomSnapRequest &+= 1
    }

    /// Slices the message list to the active window: the last
    /// `transcriptWindowSize` messages plus any older ones the user has
    /// explicitly expanded via "Show earlier". Frozen (out-of-window) messages
    /// are not in the returned array, so the `ForEach` doesn't iterate them
    /// and the layout pass doesn't measure them.
    private func transcriptWindow() -> [ChatMessage] {
        let all = viewModel.messages
        let end = all.count
        let windowSize = Self.transcriptWindowSize + transcriptExtraAbove
        let start = max(0, end - windowSize)
        return Array(all[start..<end])
    }

    private var inputBar: some View {
        VStack(spacing: 4) {
            if let error = viewModel.errorText {
                HStack {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $viewModel.input, axis: .vertical)
                    .font(.body)
                    .textFieldStyle(.plain)
                    .lineLimit(1...15)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .focused($inputFocused)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                    )
                    .onKeyPress(keys: [.return, .init("\u{03}")], phases: .down) { press in
                        if press.modifiers.contains(.shift) {
                            viewModel.input += "\n"
                            return .handled
                        }
                        if supervisor.state == .ready, viewModel.canSend {
                            submitMessage()
                        }
                        return .handled
                    }
                    .disabled(supervisor.state != .ready)

                Button {
                    if viewModel.isStreaming {
                        viewModel.stop()
                    } else {
                        submitMessage()
                    }
                } label: {
                    Image(systemName: viewModel.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(viewModel.isStreaming ? .red : .accentColor)
                }
                .buttonStyle(.plain)
                .disabled(
                    supervisor.state != .ready
                        || (viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && !viewModel.isStreaming)
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: viewModel.isStreaming) { _, streaming in
            if !streaming { inputFocused = true }
        }
    }
}

/// Symmetric chat bubble adapted from mlx-serve's MessageBubble (MIT). User
/// messages get a filled accent pill; assistant messages render via the selectable
/// MarkdownText renderer in a neutral pill.
struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .user {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.role == .assistant, !message.thinking.isEmpty {
                    ThinkingDisclosure(
                        text: message.thinking,
                        streaming: message.isStreaming && message.content.isEmpty)
                }
                // Show the answer bubble once content arrives; while only reasoning is still
                // streaming (content empty, thinking present) the disclosure stands in for it,
                // so no empty bubble flashes. The non-thinking path keeps its streaming placeholder.
                if !message.content.isEmpty || (message.isStreaming && message.thinking.isEmpty) {
                    VStack(alignment: .leading, spacing: 4) {
                        if message.role == .assistant {
                            if message.isStreaming {
                                StreamingMarkdownText(message.content)
                            } else {
                                MarkdownText(message.content)
                            }
                        } else {
                            Text(message.content)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.role == .user ? Color.accentColor : Color(.controlBackgroundColor))
                    .foregroundStyle(message.role == .user ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                if message.role == .assistant, let stats = message.stats {
                    Text(Self.statsLine(stats))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }

            if message.role == .assistant {
                Spacer(minLength: 60)
            }
        }
        .contextMenu {
            Button("Copy Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
            }
        }
        // Collapse the bubble into a single accessibility node. Otherwise SwiftUI's
        // focus-responder walker recurses into every Text / HStack / padding /
        // background inside the bubble on every layout pass — the rebuild cost
        // scales with transcript size. (Dashwiz's chat does the same on its
        // MessageBubble for the same reason; their cramerpax freeze trace
        // pinned this as the dominant hot path on a long transcript.)
        .accessibilityElement(children: .combine)
    }

    /// e.g. "TTFT 640 ms · gen 1.8s · 47 tok/s" — nil parts are omitted.
    static func statsLine(_ stats: GenerationStats) -> String {
        var parts: [String] = []
        if let ttft = stats.ttftSeconds { parts.append("TTFT \(formatDuration(ttft))") }
        if let decode = stats.decodeSeconds { parts.append("gen \(formatDuration(decode))") }
        if let tps = stats.tokensPerSecond { parts.append("\(Int(tps.rounded())) tok/s") }
        return parts.joined(separator: " · ")
    }

    /// Sub-second durations render in ms, longer ones in seconds.
    static func formatDuration(_ seconds: Double) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        return String(format: "%.1fs", seconds)
    }
}

/// Think-Max reasoning, hidden by default in a collapsed disclosure. The reasoning is built
/// only when expanded, so collapsed reasoning costs nothing to render (the deltas just
/// accumulate in the model).
///
/// Rendered via `MarkdownText` (pure-SwiftUI Textual). The old `.fixedSize`/no-greedy-width
/// guards existed only to stop the NSTextView width↔height layout loop (the chat-freeze bug);
/// with no NSView in the tree that loop is structurally gone, so they're removed.
struct ThinkingDisclosure: View {
    let text: String
    let streaming: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 10)
                    Label(streaming ? "Thinking…" : "Thinking", systemImage: "brain")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                MarkdownText(text)
                    .opacity(0.9)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Minimal three-dot indicator shown while awaiting the first streamed token.
/// Fresh DS4 code (mlx-serve's original was a GPU-telemetry animation).
struct GeneratingIndicator: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 8, height: 8)
                    .opacity(1.0 - Double(index) * 0.25)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}
