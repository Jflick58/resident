import Foundation
import UIKit
import HarnessKit
import Observation

/// One open chat: its transcript and the turn in progress.
@MainActor
@Observable
final class ChatModel {
    private(set) var conversation: Conversation
    private(set) var isRunning = false
    /// Text of the assistant message being written, as received.
    private var rawText = ""
    private var rawReasoning = ""
    /// The message being written, with any leaked markup tidied for display.
    var liveText: String { OutputCleaner.clean(text: rawText, reasoning: rawReasoning).text }
    var liveReasoning: String { OutputCleaner.clean(text: rawText, reasoning: rawReasoning).reasoning }
    /// IDs of tool calls that are running now.
    private(set) var runningCalls: Set<String> = []
    private var lastToolSummary: String?
    /// What the turn is doing right now, in a few words, or nil when none is running.
    var activity: String? {
        guard isRunning else { return nil }
        if !liveText.isEmpty { return "Writing the reply" }
        return lastToolSummary ?? "Thinking"
    }
    /// What the model is doing before the first piece of a reply arrives: reading what was just added to the chat.
    var waitingFor: String {
        conversation.liveMessages.last?.role == .tool ? "Reading the result" : "Reading your message"
    }
    var errorMessage: String?

    private unowned let app: AppModel
    private var task: Task<Void, Never>?
    /// A model to answer this chat with in place of the one selected in the app, while this chat is open.
    /// Set by a Shortcuts action that names a model.
    var modelOverride: ModelRef?

    init(conversation: Conversation, app: AppModel) {
        self.conversation = conversation
        self.app = app
    }

    var preset: HarnessPreset { app.preset(conversation.presetID) }

    func setPreset(_ id: UUID) {
        conversation.presetID = id
        conversation.thinking = nil
        app.update(conversation)
    }

    /// How hard the model thinks in this chat: the agent's setting unless changed here.
    var thinking: ThinkingLevel { conversation.thinking ?? preset.thinking }

    func setThinking(_ level: ThinkingLevel) {
        conversation.thinking = level == preset.thinking ? nil : level
        app.update(conversation)
    }

    /// The result of a tool call, once it has one.
    func result(for call: ToolCall) -> Message? {
        conversation.messages.last { $0.role == .tool && $0.toolCallID == call.id }
    }

    func send(_ text: String, images: [ImageAttachment] = [], documents: [DocumentAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !trimmed.isEmpty || !images.isEmpty || !documents.isEmpty else { return }

        errorMessage = nil
        if conversation.messages.isEmpty {
            conversation.title = Self.title(from: trimmed.isEmpty ? documents.first?.name ?? "Photo" : trimmed)
        }
        conversation.messages.append(.user(trimmed, images: images, documents: documents))
        conversation.updatedAt = Date()
        app.update(conversation)
        run()
    }

    /// Waits for the turn in progress, if any, to end.
    func waitForTurn() async {
        await task?.value
    }

    /// Waits for the turn in progress to end, for at most this long. True when no turn is left running.
    func waitForTurn(upTo seconds: TimeInterval) async -> Bool {
        let giveUp = Date().addingTimeInterval(seconds)
        while isRunning, Date() < giveUp {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return !isRunning
    }

    /// The reply to the latest message, once it has been written.
    var lastReply: String? {
        guard let asked = conversation.messages.lastIndex(where: { $0.role == .user }) else { return nil }
        return conversation.messages.dropFirst(asked).last { $0.role == .assistant && $0.toolCalls.isEmpty && !$0.text.isEmpty }?.text
    }

    /// Sends a message and waits for the turn to end. Returns the reply's text, or nil if there was none.
    func sendAndWait(_ text: String) async -> String? {
        let before = conversation.messages.count
        send(text)
        await task?.value
        return conversation.messages.dropFirst(before).last { $0.role == .assistant && !$0.text.isEmpty }?.text
    }

    /// True when the last turn was cut off before it finished and can be carried on.
    var canContinue: Bool { !isRunning && conversation.turnInProgress == true }

    /// Carries on with an unfinished turn from the last completed step. Tool
    /// results already in the transcript are kept, so finished searches and page
    /// reads are not repeated; only the step that was cut off runs again.
    func continueTurn() {
        guard canContinue else { return }
        errorMessage = nil
        // Drop what the cut-off step left behind: a half-written reply, or tool
        // calls that never got their results.
        while let last = conversation.messages.last, last.role == .assistant {
            let answered = last.toolCalls.allSatisfy { call in result(for: call) != nil }
            if !last.toolCalls.isEmpty && answered { break }
            conversation.messages.removeLast()
        }
        guard conversation.messages.contains(where: { $0.role == .user }) else {
            conversation.turnInProgress = nil
            return
        }
        run()
    }

    /// Stops an on-device turn because the app is leaving the foreground.
    func pauseForBackground() {
        guard isRunning else { return }
        pausedForBackground = true
        task?.cancel()
    }

    /// Carries on with a turn that `pauseForBackground` stopped.
    func resumeIfPaused() {
        guard pausedForBackground, !isRunning else { return }
        pausedForBackground = false
        continueTurn()
    }

    private(set) var pausedForBackground = false

    /// Runs the turn again from the last user message.
    func retry() {
        guard !isRunning, let lastUser = conversation.messages.lastIndex(where: { $0.role == .user }) else { return }
        conversation.messages.removeSubrange((lastUser + 1)...)
        errorMessage = nil
        run()
    }

    /// Answers a message again: everything after the user message that led to it is dropped.
    func regenerate(_ message: Message) {
        guard !isRunning, let index = conversation.messages.firstIndex(where: { $0.id == message.id }),
            let user = conversation.messages[...index].lastIndex(where: { $0.role == .user })
        else { return }
        conversation.messages.removeSubrange((user + 1)...)
        errorMessage = nil
        run()
    }

    /// Changes what a user message says and answers it afresh. Its attachments
    /// are kept; everything that came after it is dropped.
    func edit(_ message: Message, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, let index = conversation.messages.firstIndex(where: { $0.id == message.id }),
            conversation.messages[index].role == .user,
            !trimmed.isEmpty || !message.images.isEmpty || !(message.documents ?? []).isEmpty
        else { return }
        conversation.messages[index].text = trimmed
        conversation.messages.removeSubrange((index + 1)...)
        if index == 0 {
            conversation.title = Self.title(from: trimmed.isEmpty ? conversation.title : trimmed)
            conversation.isTitled = nil
        }
        conversation.updatedAt = Date()
        errorMessage = nil
        run()
    }

    /// Stops the turn, keeping what was written. `reason` is shown to the user when the stop was not their choice.
    func stop(reason: String? = nil) {
        stopReason = reason
        userStopped = true
        task?.cancel()
    }

    private var userStopped = false

    private var stopReason: String?

    private func run() {
        isRunning = true
        // Until `finish`: the model's weights are not let go while a tool runs between two of its replies.
        app.turnBegan()
        lastToolSummary = nil
        userStopped = false
        conversation.turnInProgress = true
        app.update(conversation)
        let preset = preset
        task = Task {
            do {
                // The model does one thing at a time: let any tidying-up after an earlier reply stop first.
                await app.stopHousekeeping()
                let model = try await app.resolveModel(modelOverride ?? app.library.selected)
                // A model without tool support gets none, rather than a prompt it cannot follow.
                var (tools, groups) = model.capabilities.tools ? app.toolSet(for: preset) : ([], [])
                // Attachments are given to the model in the form it can take: the
                // opening of each document plus a tool to read the rest, and the
                // text found in photos when the model cannot see them.
                let documents = conversation.liveMessages.flatMap { $0.documents ?? [] }
                if model.capabilities.tools, !documents.isEmpty { tools.append(ReadDocumentTool(documents: documents)) }
                let transcript = conversation.liveMessages.map {
                    AttachmentRenderer.render($0, vision: model.capabilities.vision, canReadMore: model.capabilities.tools)
                }
                let system = Message.system(PromptBuilder.systemPrompt(
                    preset: preset, memory: app.memoryText, skills: app.skills, connectors: groups,
                    canRemember: model.capabilities.tools && app.memoryEnabled && preset.tools.contains(.saveMemory),
                    earlier: conversation.activeSummary))
                var agent = Agent(
                    provider: model.provider, tools: tools,
                    options: preset.options(sampling: model.sampling, thinking: conversation.thinking),
                    // Leave room in the context for the reply itself.
                    contextBudgetTokens: max(2048, model.contextTokens - preset.maxOutputTokens))
                agent.groups = groups
                // For a model that answers some requests without tools: the same prompt with nothing about them.
                var plain = preset
                plain.tools = []
                agent.plainInstructions = PromptBuilder.systemPrompt(
                    preset: plain, memory: app.memoryText, canRemember: false, earlier: conversation.activeSummary)
                agent.loadedToolNames = conversation.loadedTools ?? []

                for try await event in agent.run(messages: [system] + transcript) {
                    handle(event)
                }
            } catch is CancellationError {
                keepPartialReply()
            } catch let error as ModelStoppedError {
                keepPartialReply()
                if UIApplication.shared.applicationState == .active {
                    errorMessage = error.localizedDescription
                } else {
                    // iOS withdrew the graphics processor because the app is not on
                    // screen. Not a failure: the turn carries on when the app is opened.
                    pausedForBackground = true
                }
            } catch {
                keepPartialReply()
                errorMessage = error.localizedDescription
            }
            finish()
        }
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .textDelta(let delta):
            rawText += delta
        case .reasoningDelta(let delta):
            rawReasoning += delta
        case .assistantMessage(let message):
            rawText = ""
            rawReasoning = ""
            // Skip a message with nothing in it, which a cancelled step can produce.
            if !message.text.isEmpty || !message.toolCalls.isEmpty || !message.reasoning.isEmpty {
                conversation.messages.append(message)
            }
            if message.toolCalls.isEmpty { turnCompleted = true }
        case .toolStarted(let call, let summary):
            lastToolSummary = summary
            runningCalls.insert(call.id)
        case .toolFinished(let message):
            if let id = message.toolCallID { runningCalls.remove(id) }
            conversation.messages.append(message)
            // Save after every finished step, so the work survives the app being closed.
            app.update(conversation)
        case .toolsLoaded(let names):
            conversation.loadedTools = names
        case .finished(let reason):
            if reason == .cancelled { keepPartialReply() }
            if reason == .length {
                errorMessage = "The reply reached this agent's length limit. Ask it to continue, or raise the limit in the agent."
            }
        }
    }

    /// Keeps whatever was written before a stop or failure.
    private func keepPartialReply() {
        let cleaned = OutputCleaner.clean(text: rawText, reasoning: rawReasoning)
        if !cleaned.text.isEmpty {
            var message = Message.assistant(cleaned.text)
            message.reasoning = cleaned.reasoning
            conversation.messages.append(message)
        }
        rawText = ""
        rawReasoning = ""
    }

    private var turnCompleted = false

    /// The reply a skill is being drafted from, while that is under way.
    private(set) var draftingSkillFor: UUID?

    /// The turn a reply ended: the user's message and everything up to the reply.
    private func turn(endingAt message: Message) -> [Message]? {
        guard let end = conversation.messages.firstIndex(where: { $0.id == message.id }),
            let start = conversation.messages[...end].lastIndex(where: { $0.role == .user })
        else { return nil }
        return Array(conversation.messages[start...end])
    }

    /// Whether a reply ended a turn with enough steps in it to be worth saving as a skill.
    func isSkillWorthy(_ message: Message) -> Bool {
        guard preset.tools.contains(.skills), let turn = turn(endingAt: message) else { return false }
        return turn.reduce(0) { $0 + $1.toolCalls.count } >= Housekeeping.skillWorthyToolCalls
    }

    /// Drafts a skill from the turn a reply ended and shows it to the user to keep, change or discard.
    func draftSkill(from message: Message) {
        guard !isRunning, draftingSkillFor == nil, let turn = turn(endingAt: message) else { return }
        draftingSkillFor = message.id
        errorMessage = nil
        // In the tidying-up slot, so it stops like the rest when the app leaves the screen.
        let earlier = housekeeping
        earlier?.cancel()
        housekeeping = Task {
            defer { draftingSkillFor = nil }
            await earlier?.value
            guard !Task.isCancelled, let model = try? await app.resolveModel(modelOverride ?? app.library.selected),
                let draft = await Housekeeping.skillDraft(from: turn, provider: model.provider)
            else {
                errorMessage = "A skill could not be drafted from that reply. Ask the assistant to save it as a skill instead."
                return
            }
            _ = await app.propose(draft)
        }
    }

    /// The size of a chat, in tokens the model is given, above which its older part is summarised.
    static let summariseAboveTokens = 5000

    /// Work done with the model after a reply, out of the user's way.
    private var housekeeping: Task<Void, Never>?

    /// Stops the tidying-up, because the app is leaving the screen or a new turn is starting.
    func cancelHousekeeping() {
        housekeeping?.cancel()
    }

    /// Stops the tidying-up and waits until the model is free.
    func stopHousekeeping() async {
        let running = housekeeping
        housekeeping = nil
        running?.cancel()
        await running?.value
    }

    /// After a finished reply: put any lasting fact from the user's message in
    /// memory, and give a new chat a name. Each is a short request of its own,
    /// because a model busy answering does neither reliably.
    private func tidyUp(usedMemoryTool: Bool) {
        let preset = preset
        let id = conversation.id
        guard let question = conversation.messages.last(where: { $0.role == .user }),
            let answer = conversation.messages.last(where: { $0.role == .assistant && !$0.text.isEmpty })
        else { return }
        let keepsMemory = app.memoryEnabled && preset.tools.contains(.saveMemory) && !usedMemoryTool
        let needsTitle = conversation.isTitled != true && conversation.messages.filter { $0.role == .user }.count == 1
        // A long chat is slow to pick up and crowds out new work: once it passes
        // this size, everything but the last two exchanges is put into a summary.
        let live = conversation.liveMessages
        let size = live.reduce(0) { total, message in
            total + ContextBudget.estimateTokens(message.role == .tool ? String(message.text.prefix(600)) : message.text) + 8
        }
        let turnStarts = live.indices.filter { live[$0].role == .user }
        let cut = turnStarts.count > 2 ? turnStarts[turnStarts.count - 2] : 0
        // Sooner for a model that takes less: Apple's holds 8,192 tokens in all.
        let limit = min(Self.summariseAboveTokens, app.selectedContextTokens * 2 / 5)
        let toSummarise = size > limit && cut > 0 ? Array(live[..<cut]) : []
        guard keepsMemory || needsTitle || !toSummarise.isEmpty else { return }

        housekeeping = Task { [weak self] in
            guard let self, let model = try? await self.app.resolveModel(modelOverride ?? app.library.selected) else { return }
            if keepsMemory, !Task.isCancelled {
                let update = await Housekeeping.memoryUpdate(
                    from: question.text, known: self.app.memory.facts, provider: model.provider)
                if !update.isEmpty, !Task.isCancelled, self.conversation.id == id {
                    if !update.forget.isEmpty {
                        self.app.memory.setFacts(self.app.memory.facts.filter { !update.forget.contains($0) })
                    }
                    let added = update.facts.filter { self.app.memory.add($0) == .added }
                    if !added.isEmpty {
                        self.conversation.remembered = (self.conversation.remembered ?? [:])
                            .merging([question.id.uuidString: added]) { $1 }
                        self.app.update(self.conversation)
                    }
                }
            }
            if let last = toSummarise.last, !Task.isCancelled,
                let summary = await Housekeeping.summary(
                    of: toSummarise, previous: self.conversation.activeSummary, provider: model.provider),
                !Task.isCancelled, self.conversation.id == id
            {
                self.conversation.summary = summary
                self.conversation.summarizedThrough = last.id
                self.app.update(self.conversation)
            }
            if needsTitle, !Task.isCancelled,
                let title = await Housekeeping.title(question: question.text, answer: answer.text, provider: model.provider),
                !Task.isCancelled, self.conversation.id == id
            {
                self.conversation.title = title
                self.conversation.isTitled = true
                self.app.update(self.conversation)
            }
        }
    }

    private func finish() {
        isRunning = false
        app.turnEnded()
        if turnCompleted, !userStopped, errorMessage == nil, stopReason == nil {
            let lastUser = conversation.messages.lastIndex { $0.role == .user } ?? 0
            let usedMemory = conversation.messages[lastUser...].contains {
                $0.toolCalls.contains { $0.name == BuiltInTool.saveMemory.rawValue }
            }
            tidyUp(usedMemoryTool: usedMemory)
        }
        // A turn the user stopped, or that ran to its end or failed, is over. One
        // cut off by the app going to the background stays open to be carried on.
        if turnCompleted || userStopped || !pausedForBackground { conversation.turnInProgress = nil }
        turnCompleted = false
        if let stopReason, errorMessage == nil { errorMessage = stopReason }
        stopReason = nil
        runningCalls = []
        rawText = ""
        rawReasoning = ""
        task = nil
        conversation.updatedAt = Date()
        app.update(conversation)
    }

    static func title(from text: String) -> String {
        let line = text.components(separatedBy: .newlines).first ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "New Chat" }
        return trimmed.count > 48 ? String(trimmed.prefix(48)) + "…" : trimmed
    }
}
