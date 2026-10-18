import PiDurableKit
import SwiftUI

struct ThreadView: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadMeta

    @State private var view: ConversationView?
    @State private var draft = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    private var busy: Bool { view?.isBusy ?? false }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let view {
                        Transcript(view: view)
                    }
                    if let error {
                        Text(error).font(.mono(12)).foregroundStyle(Theme.danger).hairlineCard(padding: 10)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: view?.entries.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: view?.streamingMessage?.text) { proxy.scrollTo("end", anchor: .bottom) }
        }
        .canvasBackground()
        .safeAreaInset(edge: .top, spacing: 0) {
            if busy {
                ProgressView().progressViewStyle(.linear).tint(Theme.accent).frame(height: 2)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Composer(text: $draft, busy: busy, focused: $focused, model: view?.agent.model, send: send, stop: stop)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(view.map { _ in currentTitle } ?? thread.title).font(.mono(13, weight: .medium)).lineLimit(1)
                    MonoLabel(busy ? "Running" : "Idle", color: busy ? Theme.accentSoft : Theme.inkFaint, size: 9)
                        .accessibilityIdentifier(busy ? "status.running" : "status.idle")
                }
            }
        }
        .task(id: thread.id) { await observe() }
    }

    private var currentTitle: String {
        app.threads.first(where: { $0.id == thread.id })?.title ?? thread.title
    }

    private func observe() async {
        do {
            guard let conversation = try await app.conversation(thread.id) else { return }
            for try await next in conversation.views() {
                view = next
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task {
            do {
                try await app.send(text, to: thread, steer: busy)
                error = nil
            } catch {
                self.error = error.localizedDescription
                draft = text
            }
        }
    }

    private func stop() {
        Task { try? await app.stop(thread) }
    }
}

// MARK: - Transcript

/// The conversation as a console: user turns as bordered blocks, assistant prose, numbered tool rows.
private struct Transcript: View {
    let view: ConversationView

    var body: some View {
        let results = toolResults
        let numbers = toolNumbers
        ForEach(view.entries) { entry in
            switch entry.kind {
            case .user:
                UserTurn(text: entry.userMessage.map(text(of:)) ?? entry.text)
            case .assistant:
                if let message = entry.assistantMessage {
                    AssistantTurn(message: message, results: results, numbers: numbers)
                }
            default:
                EmptyView()
            }
        }
        if let partial = view.streamingMessage {
            AssistantTurn(message: partial, results: results, numbers: numbers, live: view.live.tools)
        } else if view.isBusy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini).tint(Theme.accentSoft)
                MonoLabel(view.live.tools.isEmpty ? "Thinking" : "Working", color: Theme.accentSoft, size: 10)
            }
        }
        if let error = view.entries.last?.assistantMessage?.errorMessage {
            Text(error).font(.mono(11)).foregroundStyle(Theme.danger).hairlineCard(padding: 10)
        }
    }

    /// Tool calls numbered 01, 02, … in transcript order, including the one being generated.
    private var toolNumbers: [String: Int] {
        var numbers: [String: Int] = [:]
        let messages = view.entries.compactMap(\.assistantMessage) + [view.streamingMessage].compactMap { $0 }
        for message in messages {
            for case .toolCall(let call) in message.content where numbers[call.id] == nil {
                numbers[call.id] = numbers.count + 1
            }
        }
        return numbers
    }

    private var toolResults: [String: ToolResultMessage] {
        var results: [String: ToolResultMessage] = [:]
        for entry in view.entries where entry.kind == .toolResult {
            if let result = entry.toolResult { results[result.toolCallId] = result }
        }
        return results
    }

    private func text(of message: UserMessage) -> String {
        message.content.compactMap(\.text).joined(separator: "\n")
    }
}

private struct UserTurn: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoLabel("You", color: Theme.inkFaint, size: 9.5)
            Text(text).font(.grotesk(16)).foregroundStyle(Theme.ink).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairlineCard(padding: 14, fill: Theme.raised)
    }
}

private struct AssistantTurn: View {
    let message: AssistantMessage
    let results: [String: ToolResultMessage]
    let numbers: [String: Int]
    var live: [LiveState.ToolSlot] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(message.content.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text) where !text.isEmpty:
                    Prose(text: text)
                case .thinking(let text, _) where !text.isEmpty:
                    ThinkingRow(text: text)
                case .toolCall(let call):
                    ToolRow(
                        index: numbers[call.id] ?? 0, call: call, result: results[call.id],
                        live: live.first(where: { $0.callId == call.id }))
                default:
                    EmptyView()
                }
            }
        }
    }
}

private struct Prose: View {
    let text: String

    var body: some View {
        Text(markdown)
            .font(.grotesk(16))
            .foregroundStyle(Theme.ink)
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("assistantText")
    }

    private var markdown: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct ThinkingRow: View {
    let text: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                    MonoLabel("Thinking", color: Theme.inkFaint, size: 9.5)
                }
                .foregroundStyle(Theme.inkFaint)
            }
            .buttonStyle(.plain)
            if open {
                Text(text).font(.grotesk(13)).foregroundStyle(Theme.inkMuted)
            }
        }
    }
}

/// `01 bash  ls -la   ✓ 0.4s` — one tool call, expandable to its output.
private struct ToolRow: View {
    let index: Int
    let call: ToolCall
    let result: ToolResultMessage?
    let live: LiveState.ToolSlot?
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) { open.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(String(format: "%02d", index)).font(.mono(11)).foregroundStyle(Theme.accentSoft)
                    Text(call.name).font(.mono(12.5, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(summary).font(.mono(12)).foregroundStyle(Theme.inkMuted).lineLimit(1)
                    Spacer(minLength: 4)
                    status
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open, let output, !output.isEmpty {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                ScrollView(.horizontal) {
                    Text(output).font(.mono(11.5)).foregroundStyle(Theme.inkMuted).textSelection(.enabled)
                        .padding(12)
                }
                .frame(maxHeight: 320)
            }
        }
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }

    @ViewBuilder private var status: some View {
        if let result {
            HStack(spacing: 4) {
                Image(systemName: result.isError ? "xmark" : "checkmark")
                if let duration = result.duration {
                    Text(duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow, maximumUnitCount: 1)))
                }
            }
            .font(.mono(11))
            .foregroundStyle(result.isError ? Theme.danger : Theme.success)
        } else {
            ProgressView().controlSize(.mini).tint(Theme.accentSoft)
        }
    }

    private var summary: String {
        guard let first = call.arguments.sorted(by: { $0.key < $1.key }).first else { return "" }
        let value: String = first.value.stringValue ?? "\(first.value)"
        return value.replacingOccurrences(of: "\n", with: " ")
    }

    private var output: String? {
        if let result { return result.content.compactMap(\.text).joined(separator: "\n") }
        return live?.output
    }
}
