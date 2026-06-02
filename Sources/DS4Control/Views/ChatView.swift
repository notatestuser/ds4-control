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

    /// Extra older messages the user has explicitly expanded into the window via
    /// the "Show earlier" button. Reset to 0 on `clear` (handled by the
    /// `onChange` of `messages.count` — if the user clears, the window starts
    /// fresh; if they keep chatting, the window keeps whatever they've loaded).
    @State private var transcriptExtraAbove = 0

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
                                Text("Show \(min(hiddenAbove, Self.transcriptWindowSize)) earlier message\(hiddenAbove == 1 ? "" : "s")")
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
                        .id("generating-indicator")
                    }
                }
                .padding(16)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                // Scroll to the bottom once per new message (i.e. once on Enter).
                // No other onChange handler — the streaming `content` and `thinking`
                // mutations are NOT scrolled-to here, so the viewport doesn't
                // continuously re-anchor as the assistant streams. The CSS
                // `overflow-anchor: auto` analogue: the scroll position adjusts once
                // when a new bubble is committed; while the user is reading or
                // the model is streaming, the position is preserved.
                scrollToBottom(proxy, animated: true)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("generating-indicator", anchor: .bottom) }
        } else {
            proxy.scrollTo("generating-indicator", anchor: .bottom)
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
                            MarkdownText(message.content.isEmpty && message.isStreaming ? " " : message.content)
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

/// Think-Max reasoning, hidden by default in a collapsed disclosure. Expanding reveals the
/// monologue inline (the outer transcript scrolls if it's long). State is per-message (the bubble
/// carries `.id(message.id)`), so expansion sticks per reply.
///
/// Deliberately NO inner ScrollView AND NO `.frame(maxWidth: .infinity)`: a greedy-width child
/// inside the content-sized bubble made the offered width oscillate against the sibling
/// IntrinsicTextView's pure sizeThatFits, spinning the SwiftUI layout engine at 100% CPU
/// (the chat-freeze bug). Plain Text with no width-frame sizes deterministically.
///
/// `.fixedSize(horizontal: false, vertical: true)` on the disclosure (and on the inner Text)
/// matches dashwiz's pattern: take the parent's offered width, but let the view's height
/// follow its content exactly. Without it, the disclosure's animated expand/collapse can
/// re-measure its parent during the animation, and the content-sized bubble column
/// (MessageBubble's outer VStack) re-lays out on every content change inside the disclosure.
struct ThinkingDisclosure: View {
    let text: String
    let streaming: Bool
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        } label: {
            Label(streaming ? "Thinking…" : "Thinking", systemImage: "brain")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Collapse the disclosure's view tree (DisclosureGroup + label Text +
        // padding + background) into one accessibility node. Mirrors the
        // bubble-level `.combine` on MessageBubble and dashwiz's combine on
        // PhaseBoxView; same reasoning — the focus-responder walker otherwise
        // recurses into every child on every layout pass.
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
