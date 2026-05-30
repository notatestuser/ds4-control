// Chat UI ported from mlx-serve (MIT, Copyright 2026 David):
// app/Sources/MLXServe/Views/ChatView.swift. The transcript layout, near-bottom
// auto-scroll (PreferenceKey-based), MessageBubble and the iMessage-style input bar
// are adapted from that source, stripped of mlx-serve's agent/tools/MCP/multi-session
// machinery for DS4's single conversation. GeneratingIndicator is fresh DS4 code (the
// original drove IOKit/Mach GPU telemetry on a polling Timer, unsuitable here).

import AppKit
import SwiftUI

private struct ContentBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollViewHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ChatView: View {
    @EnvironmentObject var supervisor: SupervisorService
    @ObservedObject var viewModel: ChatViewModel

    @FocusState private var inputFocused: Bool
    @State private var isNearBottom = true
    @State private var contentBottom: CGFloat = 0
    @State private var scrollViewHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            inputBar
        }
        .frame(minWidth: 560, minHeight: 640)
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
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: ContentBottomKey.self,
                                    value: geo.frame(in: .named("chatScroll")).maxY
                                )
                            }
                        )
                }
                .padding(16)
            }
            .coordinateSpace(name: "chatScroll")
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ScrollViewHeightKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(ContentBottomKey.self) { bottom in
                contentBottom = bottom
                if bottom - scrollViewHeight < 60 { isNearBottom = true }
            }
            .onPreferenceChange(ScrollViewHeightKey.self) { height in
                scrollViewHeight = height
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if isNearBottom { scrollToBottom(proxy) }
            }
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                if isNearBottom { scrollToBottom(proxy) }
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
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { inputFocused = true }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
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
                if !message.content.isEmpty || message.isStreaming {
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
