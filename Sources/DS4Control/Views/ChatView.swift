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
    @EnvironmentObject var supervisor: SupervisorService
    @ObservedObject var viewModel: ChatViewModel

    @FocusState private var inputFocused: Bool
    /// Whether the transcript is pinned to the bottom. Driven by the bottom anchor's
    /// visibility: true while the latest message is on-screen, false once the user scrolls
    /// up — so auto-scroll follows new content only when they haven't scrolled away.
    @State private var atBottom = true

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
                    ForEach(viewModel.messages) { message in
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
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                        // Bottom-anchor visibility drives `atBottom`: visible ⇒ pinned to the
                        // latest message; once it scrolls off, the user has scrolled up.
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(16)
            }
            // Auto-scroll to the latest message, but only while pinned to the bottom — if the
            // user scrolled up to read history, leave them there. A new generation re-pins so
            // the reply is followed.
            .onChange(of: viewModel.messages.count) { _, _ in if atBottom { scrollToBottom(proxy) } }
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                if atBottom { scrollToBottom(proxy, animated: false) }
            }
            .onChange(of: viewModel.isStreaming) { _, streaming in
                if streaming { atBottom = true; scrollToBottom(proxy) }
                else if atBottom { scrollToBottom(proxy) }  // reveal the TTFT/stats line on completion
            }
        }
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

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        // Instant during streaming (token-by-token) to avoid stacking animations; animated
        // for discrete new messages.
        if animated {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
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
                                .textSelection(.enabled)
                        } else {
                            Text(message.content)
                                .textSelection(.enabled)
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
/// monologue (capped, internally scrollable so long reasoning doesn't blow up the bubble).
/// State is per-message (the bubble carries `.id(message.id)`), so expansion sticks per reply.
struct ThinkingDisclosure: View {
    let text: String
    let streaming: Bool
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .padding(.top, 4)
        } label: {
            Label(streaming ? "Thinking…" : "Thinking", systemImage: "brain")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
