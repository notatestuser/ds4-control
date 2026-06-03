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

    /// Stable id of a 1 pt anchor pinned to the end of the transcript, so the scroll view can be
    /// told to follow the bottom as the latest reply streams in.
    private static let bottomAnchorID = "transcript-bottom"

    /// Extra older messages the user has explicitly expanded into the window via
    /// the "Show earlier" button. Reset to 0 on `clear` (handled by the
    /// `onChange` of `messages.count` — if the user clears, the window starts
    /// fresh; if they keep chatting, the window keeps whatever they've loaded).
    @State private var transcriptExtraAbove = 0

    /// Drives the bottom-follow while a reply streams (and briefly after); cancelled when it ends.
    @State private var followTask: Task<Void, Never>?

    /// Whether the user is still pinned to the bottom. False while they've scrolled up (so the
    /// follow pauses and lets them read); true again once they return to the bottom.
    @State private var userPinnedToBottom = true

    /// Scroll metrics observed (via `onScrollGeometryChange`) to drive the follow guard.
    private struct ScrollMetrics: Equatable {
        var offsetY: CGFloat
        var distanceFromBottom: CGFloat
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    let window = transcriptWindow()
                    let hiddenAbove = viewModel.messages.count - window.count
                    if hiddenAbove > 0 {
                        // "Show earlier" affordance — tap to grow the window backward by
                        // another `transcriptWindowSize`. Each click materialises another
                        // batch of older bubbles into the view tree, which is expensive
                        // (re-measures, lays out, invalidates the layout cache) — but it's
                        // an explicit user action, not a per-token cost.
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
                    }
                    ForEach(window) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if viewModel.isStreaming && !viewModel.hasReceivedFirstToken {
                        HStack {
                            GeneratingIndicator()
                            Spacer()
                        }
                    }
                    // Invisible tail anchor — always the last element — that the scroll view is
                    // told to follow, so the newest content stays in view.
                    Color.clear.frame(height: 1).id(Self.bottomAnchorID)
                }
                .padding(16)
            }
            // Keep the newest content in view (no `.defaultScrollAnchor` — it fought the explicit
            // scroll and flickered). New messages jump to the bottom; while a reply streams a
            // ~30 Hz loop follows the bottom, but only while the user is pinned there — scrolling
            // up pauses the follow so they can read. On finish, a single delayed re-anchor lands
            // after the bubble re-renders as one view and its layout settles.
            .onAppear {
                anchorBottom(proxy)
                if viewModel.isStreaming { startBottomFollow(proxy) }
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                userPinnedToBottom = true
                anchorBottom(proxy)
            }
            .onChange(of: viewModel.isStreaming) { _, streaming in
                if streaming { startBottomFollow(proxy) }
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
                    userPinnedToBottom = false
                } else if new.distanceFromBottom < 24 {
                    userPinnedToBottom = true
                }
            }
            .onDisappear {
                followTask?.cancel()
                followTask = nil
            }
        }
    }

    /// Scrolls the transcript so the tail anchor sits at the bottom, with animation disabled so
    /// the rapid streaming re-anchors don't visibly animate (the flicker source).
    private func anchorBottom(_ proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    /// Follows the bottom at ~30 Hz while a reply streams (only while the user stays pinned to the
    /// bottom), then — ~500 ms after streaming ends, once the bubble has re-rendered as a single
    /// view and its layout has settled — re-anchors one last time. The loop self-cancels on the
    /// next stream or on disappear.
    private func startBottomFollow(_ proxy: ScrollViewProxy) {
        followTask?.cancel()
        followTask = Task { @MainActor in
            while !Task.isCancelled && viewModel.isStreaming {
                if userPinnedToBottom { anchorBottom(proxy) }
                try? await Task.sleep(nanoseconds: 33_000_000)  // ~30 Hz
            }
            // Capture the pinned state at stream-end, before the finalize re-render (block-split →
            // single view) can shift the content height and flip the guard; if the user was
            // following, land one last anchor after it settles.
            let wasPinned = userPinnedToBottom
            try? await Task.sleep(nanoseconds: 500_000_000)  // let the finalize re-render settle
            if !Task.isCancelled && wasPinned { anchorBottom(proxy) }
        }
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
                            viewModel.send()
                        }
                        return .handled
                    }
                    .disabled(supervisor.state != .ready)

                Button {
                    if viewModel.isStreaming {
                        viewModel.stop()
                    } else {
                        viewModel.send()
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
/// accumulate in the model). State is per-message (the bubble carries `.id(message.id)`), so
/// expansion sticks per reply.
///
/// Rendered via `MarkdownText` (pure-SwiftUI Textual). The old `.fixedSize`/no-greedy-width
/// guards existed only to stop the NSTextView width↔height layout loop (the chat-freeze bug);
/// with no NSView in the tree that loop is structurally gone, so they're removed.
struct ThinkingDisclosure: View {
    let text: String
    let streaming: Bool
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                MarkdownText(text)
                    .opacity(0.9)
                    .padding(.top, 4)
            }
        } label: {
            Label(streaming ? "Thinking…" : "Thinking", systemImage: "brain")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Collapse the disclosure's view tree into one accessibility node so the
        // focus-responder walker doesn't recurse into every child on each layout pass.
        .accessibilityElement(children: .combine)
    }
}

/// Minimal three-dot pulse shown while awaiting the first streamed token.
/// Fresh DS4 code (mlx-serve's original was a GPU-telemetry animation).
struct GeneratingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 8, height: 8)
                    .opacity(animating ? 1 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .onAppear { animating = true }
    }
}
