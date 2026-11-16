import HarnessKit
import SwiftUI

struct UserMessageView: View {
    let message: Message
    let chat: ChatModel
    @State private var viewing: ImageAttachment?
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !message.images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(message.images) { image in
                        if let uiImage = UIImage(data: image.data) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 120, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .contentShape(RoundedRectangle(cornerRadius: 14))
                                .onTapGesture { viewing = image }
                                .accessibilityLabel("Photo")
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                }
            }
            ForEach(message.documents ?? []) { document in
                DocumentChip(name: document.name, detail: "\(document.parts.count) \(document.partNoun)\(document.parts.count == 1 ? "" : "s")")
            }
            if !message.text.isEmpty {
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                HStack(spacing: 2) {
                    MessageAction(title: "Copy", symbol: "doc.on.doc") { UIPasteboard.general.string = message.text }
                    MessageAction(title: "Edit", symbol: "pencil") { isEditing = true }
                        .disabled(chat.isRunning)
                }
                if let facts = chat.conversation.remembered?[message.id.uuidString], !facts.isEmpty {
                    Label("Remembered: " + facts.joined(separator: " "), systemImage: "brain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
        .fullScreenCover(item: $viewing) { PhotoViewer(image: $0) }
        .sheet(isPresented: $isEditing) {
            EditMessageView(text: message.text) { chat.edit(message, text: $0) }
        }
    }
}

/// A photo on its own, filling the screen. Pinch or double-tap to zoom.
struct PhotoViewer: View {
    let image: ImageAttachment
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var settledOffset = CGSize.zero

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let uiImage = UIImage(data: image.data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        MagnifyGesture()
                            .onChanged { scale = min(6, max(1, settledScale * $0.magnification)) }
                            .onEnded { _ in
                                settledScale = scale
                                if scale == 1 { reset() }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                guard scale > 1 else { return }
                                offset = CGSize(
                                    width: settledOffset.width + value.translation.width,
                                    height: settledOffset.height + value.translation.height)
                            }
                            .onEnded { value in
                                // Not zoomed in: a downward swipe puts the photo away.
                                if scale == 1, value.translation.height > 80 { dismiss() }
                                settledOffset = offset
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy) {
                            if scale > 1 { reset() } else { scale = 2.5; settledScale = 2.5 }
                        }
                    }
                    .accessibilityLabel("Photo")
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.2), in: Circle())
            }
            .accessibilityLabel("Close")
            .padding()
        }
    }

    private func reset() {
        scale = 1
        settledScale = 1
        offset = .zero
        settledOffset = .zero
    }
}

/// Rewrites a message already sent. Sending it answers the chat again from that point.
struct EditMessageView: View {
    @State var text: String
    var send: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($isFocused)
                .padding(.horizontal, 12)
                .navigationTitle("Edit Message")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") {
                            send(text)
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .onAppear { isFocused = true }
        }
        .presentationDetents([.medium, .large])
    }
}

/// An attached document, as a small labelled tile.
struct DocumentChip: View {
    let name: String
    let detail: String
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.subheadline).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("Remove \(name)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// One assistant step: its thinking, what it said, and the tools it used.
struct AssistantMessageView: View {
    let message: Message
    let chat: ChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !message.reasoning.isEmpty {
                ThinkingView(text: message.reasoning, seconds: message.reasoningSeconds, isLive: false)
            }
            if !message.text.isEmpty {
                MarkdownView(text: message.text)
                    .textSelection(.enabled)
            }
            ForEach(message.toolCalls) { call in
                ToolCallView(call: call, result: chat.result(for: call), isRunning: chat.runningCalls.contains(call.id))
            }
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Shown under the reply that ends a turn, not under the steps that led to it.
    @ViewBuilder private var actions: some View {
        if !message.text.isEmpty, message.toolCalls.isEmpty {
            HStack(spacing: 2) {
                MessageAction(title: "Copy", symbol: "doc.on.doc") { UIPasteboard.general.string = message.text }
                MessageAction(title: "Regenerate", symbol: "arrow.clockwise") { chat.regenerate(message) }
                    .disabled(chat.isRunning)
                if chat.draftingSkillFor == message.id {
                    ProgressView().controlSize(.mini).frame(width: 32, height: 28)
                } else if chat.isSkillWorthy(message) {
                    MessageAction(title: "Save as Skill", symbol: "book.closed") { chat.draftSkill(from: message) }
                        .disabled(chat.isRunning || chat.draftingSkillFor != nil)
                }
                if let speed = message.stats?.tokensPerSecond {
                    Text(String(format: "%.0f tokens/s", speed))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 6)
                }
            }
            .padding(.leading, -8)
        }
    }
}

/// A small icon button under a message.
struct MessageAction: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var done = false

    var body: some View {
        Button {
            action()
            // A moment of confirmation, since copying changes nothing on screen.
            done = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                done = false
            }
        } label: {
            Image(systemName: done && title == "Copy" ? "checkmark" : symbol)
                .font(.footnote)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(title)
    }
}

/// Collapsed by default: thinking is there if you want it and out of the way if you do not.
struct ThinkingView: View {
    let text: String
    let seconds: Double?
    let isLive: Bool
    @State private var isExpanded = false

    private var title: String {
        if isLive { return "Thinking" }
        guard let seconds, seconds >= 1 else { return "Thought briefly" }
        return "Thought for \(Int(seconds.rounded())) seconds"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if isLive {
                        ProgressView().controlSize(.mini)
                    }
                    Text(title)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if isLive, !isExpanded {
                // The words it is thinking right now, so a wait before a tool call or an
                // answer shows what the model is about to do. Asking the model to say so
                // itself does not work: LFM3 went straight to the call, 54 times in 54.
                Text(String(text.suffix(240)).replacingOccurrences(of: "\n", with: " "))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .padding(.leading, 12)
                    .transaction { $0.animation = nil }
            }
            if isExpanded {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5).fill(.quaternary).frame(width: 3)
                    }
                    .textSelection(.enabled)
            }
        }
    }
}

/// A tool call as one quiet line. Opens to show what was sent and what came back.
struct ToolCallView: View {
    let call: ToolCall
    let result: Message?
    let isRunning: Bool
    @Environment(AppModel.self) private var app
    @State private var isExpanded = false

    private var tool: BuiltInTool? { BuiltInTool(rawValue: call.name) }

    private var title: String {
        let arguments = call.arguments
        switch tool {
        case .webSearch:
            let query = arguments["query"]?.stringValue ?? ""
            return isRunning ? "Searching for “\(query)”" : "Searched for “\(query)”"
        case .fetchPage:
            let raw = arguments["url"]?.stringValue ?? ""
            let host = URL(string: raw)?.host?.replacingOccurrences(of: "www.", with: "") ?? raw
            return isRunning ? "Reading \(host)" : "Read \(host)"
        case .runJavaScript:
            return isRunning ? "Running code" : "Ran code"
        case .saveMemory:
            if arguments["fact"]?.stringValue?.isEmpty ?? true { return isRunning ? "Updating memory" : "Removed from memory" }
            return isRunning ? "Saving to memory" : "Saved to memory"
        case .skills:
            let name = arguments["name"]?.stringValue ?? "a skill"
            return isRunning ? "Loading the \(name) skill" : "Used the \(name) skill"
        case nil:
            if call.name == ToolCall.unreadableName { return "Tried to use a tool" }
            if call.name == ToolGroup.openerName {
                let wanted = call.arguments["connector"]?.stringValue ?? ""
                let name = app.connectors.servers.first { $0.toolPrefix == wanted }?.name ?? "a connector"
                return isRunning ? "Opening \(name)" : "Opened \(name)"
            }
            if call.name == ReadDocumentTool.name { return isRunning ? "Reading the document" : "Read the document" }
            if call.name == SaveSkillTool.name { return isRunning ? "Proposing a skill" : "Proposed a skill" }
            if call.name == UpdateSkillTool.name { return isRunning ? "Proposing a change to a skill" : "Proposed a change to a skill" }
            return Connector.activity(forTool: call.name, isRunning: isRunning)
                ?? app.connectors.activity(forTool: call.name) ?? call.name
        }
    }

    private var input: String {
        switch tool {
        case .runJavaScript: return call.arguments["code"]?.stringValue ?? ""
        case .saveMemory: return call.arguments["fact"]?.stringValue ?? call.arguments["forget"]?.stringValue ?? ""
        case .fetchPage: return call.arguments["url"]?.stringValue ?? ""
        case .webSearch, .skills: return ""
        case nil: return call.name == ToolGroup.openerName ? call.arguments["need"]?.stringValue ?? "" : call.arguments.jsonString
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Group {
                        if isRunning {
                            ProgressView().controlSize(.mini)
                        } else if result?.isError == true {
                            Image(systemName: "exclamationmark.triangle")
                        } else {
                            Image(systemName: tool?.symbol ?? "wrench.and.screwdriver")
                        }
                    }
                    .frame(width: 18)
                    Text(title).lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !input.isEmpty {
                        Text(input)
                            .font(.system(.caption, design: .monospaced))
                    }
                    if let result {
                        if !input.isEmpty { Divider() }
                        Text(result.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(result.isError ? .red : .secondary)
                            .lineLimit(24)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

/// The assistant message while it is still being written.
struct LiveMessageView: View {
    let chat: ChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !chat.liveReasoning.isEmpty {
                ThinkingView(text: chat.liveReasoning, seconds: nil, isLive: chat.liveText.isEmpty)
            }
            if !chat.liveText.isEmpty {
                MarkdownView(text: chat.liveText)
            } else if chat.liveReasoning.isEmpty, chat.runningCalls.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Marks where a long chat was summarised: the model is given a summary of what is above.
struct SummaryMarker: View {
    let summary: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    VStack { Divider() }
                    Label("Summarised above", systemImage: "arrow.up.and.line.horizontal.and.arrow.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    VStack { Divider() }
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the summary the assistant is given in place of earlier messages")
            if isExpanded {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
