import Foundation

public enum AgentEvent: Sendable {
    case textDelta(String)
    case reasoningDelta(String)
    /// A finished assistant message. It may carry tool calls, in which case the loop continues.
    case assistantMessage(Message)
    case toolStarted(ToolCall, summary: String)
    /// A finished tool message answering one call.
    case toolFinished(Message)
    /// The connector tools declared to the model changed. Carries all of their
    /// names, to be handed back as `loadedToolNames` on the next turn.
    case toolsLoaded([String])
    case finished(StopReason)
}

/// The agent loop: generate, run any requested tools, feed the results back,
/// repeat until the model answers or the step limit is reached.
///
/// It is deliberately small. Small models have little context to spare, so the
/// loop's job is to keep each step cheap: bounded tool output, a bounded number
/// of steps, and a transcript that fits the context budget.
public struct Agent: Sendable {
    public var provider: any ModelProvider
    public var tools: [any Tool]
    public var options: GenerationOptions
    /// Model round trips allowed in one turn. The last one runs without tools so
    /// the model has to answer.
    public var maxSteps: Int
    /// Largest tool result passed back to the model, in characters.
    public var maxToolResultCharacters: Int
    /// Approximate context size to stay within, in tokens.
    public var contextBudgetTokens: Int
    /// Names of the tools declared to the model up front. Nil declares all of
    /// them. Tools left out can still be called: the model learns about them
    /// later in the conversation (see `ToolDisclosure`), which keeps a large
    /// tool set out of the prompt.
    public var declaredToolNames: Set<String>?
    /// Connectors whose tools are held back until the model opens them.
    public var groups: [ToolGroup] = []
    /// Connector tools already declared earlier in the conversation.
    public var loadedToolNames: [String] = []
    /// When the turn should be wrapping up. A step that starts after this is the
    /// last: the model is told to answer with what it has, without thinking it
    /// over. For work that something else is waiting on, such as a Shortcuts action.
    public var deadline: Date?

    public init(
        provider: any ModelProvider, tools: [any Tool] = [], options: GenerationOptions = .init(),
        maxSteps: Int = 8, maxToolResultCharacters: Int = 6000, contextBudgetTokens: Int = 12000
    ) {
        self.provider = provider
        self.tools = tools
        self.options = options
        self.maxSteps = maxSteps
        self.maxToolResultCharacters = maxToolResultCharacters
        self.contextBudgetTokens = contextBudgetTokens
    }

    /// Runs one user turn. `messages` is the full transcript, system prompt first.
    public func run(messages: [Message]) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let reason = try await loop(messages: messages, emit: { continuation.yield($0) })
                    continuation.yield(.finished(reason))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.finished(.cancelled))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The system prompt with nothing in it about tools. Passed on to the provider, which
    /// may use it for a request it answers without any. See ``GenerationRequest/plainInstructions``.
    public var plainInstructions: String?

    /// Tool results from turns that are over are made this small, in characters.
    /// The answer that used them is in the chat; what is kept is enough to refer
    /// back to (the items and what identifies them). A small model reads its whole
    /// context again at the start of each turn, so this is also what keeps a long
    /// chat quick to pick up.
    public var pastToolResultCharacters = 600

    private func loop(messages: [Message], emit: (AgentEvent) -> Void) async throws -> StopReason {
        var transcript = messages
        if let lastUser = transcript.lastIndex(where: { $0.role == .user }) {
            for index in transcript.indices where index < lastUser && transcript[index].role == .tool {
                transcript[index].text = ResultFit.fit(transcript[index].text, limit: pastToolResultCharacters)
            }
        }
        var shelf = ToolShelf(groups: groups, loaded: loadedToolNames, contextTokens: contextBudgetTokens)
        let toolsByName = Dictionary((tools + shelf.allTools).map { ($0.spec.name, $0) }, uniquingKeysWith: { a, _ in a })
        let ownSpecs = tools.map(\.spec) + (shelf.isEmpty ? [] : [shelf.spec])
        let alwaysDeclared = ownSpecs.filter { declaredToolNames?.contains($0.name) ?? true }
        let request = messages.last { $0.role == .user }?.text ?? ""
        // Tools the chat has called are the last to make way for new ones.
        for message in messages where message.role == .assistant { for call in message.toolCalls { shelf.touch(call.name) } }
        let refreshed = shelf.refresh(for: request)
        if shelf.preload(for: request) || refreshed { emit(.toolsLoaded(shelf.loaded)) }
        // Read once, so the start of the prompt stays the same for the whole turn.
        let usageNotes = shelf.usageNotes
        var seenCalls: [String: Int] = [:]
        var seenResults: Set<String> = []
        var stepOptions = options
        var recoveredFromOverthinking = false
        var carriedReasoning = ""
        // Set when the last step has to be asked again with no tools declared.
        var answerWithoutTools = false

        var step = 0
        while step < max(1, maxSteps) || answerWithoutTools {
            step += 1
            try Task.checkCancellation()
            let outOfTime = step > 1 && deadline.map { Date() >= $0 } ?? false
            let isLastStep = step >= maxSteps || outOfTime || answerWithoutTools
            var stepMessages = ContextBudget.fit(transcript, budgetTokens: contextBudgetTokens)
            if let usageNotes, stepMessages.first?.role == .system { stepMessages[0].text += "\n\n" + usageNotes }
            if isLastStep, stepMessages.last?.role == .tool {
                // Out of steps: say so, or a model that still wants a tool writes a call and no answer.
                stepMessages.append(.user("You have no tool calls left. Answer now using what you already have."))
            }
            if outOfTime { stepOptions.thinking = .off }
            // The tools stay declared on the last step. Taking them away changes the
            // start of the prompt, so a model on the device reads the whole chat again:
            // nearly two minutes for 7,750 tokens with the app off screen. They go
            // only if the model, told it has no calls left, makes one anyway.
            var generation = GenerationRequest(
                messages: stepMessages,
                tools: answerWithoutTools ? [] : alwaysDeclared + shelf.loadedSpecs,
                callableTools: answerWithoutTools ? [] : ownSpecs + shelf.loadedSpecs,
                options: stepOptions)
            generation.plainInstructions = plainInstructions

            var text = ""
            var reasoning = ""
            var calls: [ToolCall] = []
            var stop = StopReason.stop
            var stats: GenerationStats?
            let started = Date()
            var reasoningEnded: Date?

            for try await event in provider.generate(generation) {
                try Task.checkCancellation()
                switch event {
                case .text(let delta):
                    if reasoningEnded == nil, !reasoning.isEmpty { reasoningEnded = Date() }
                    text += delta
                    emit(.textDelta(delta))
                case .reasoning(let delta):
                    reasoning += delta
                    emit(.reasoningDelta(delta))
                case .toolCall(let call):
                    if reasoningEnded == nil, !reasoning.isEmpty { reasoningEnded = Date() }
                    calls.append(call)
                case .finished(let reason, let finalStats):
                    stop = reason
                    stats = finalStats
                }
            }

            var cleaned = OutputCleaner.clean(text: text, reasoning: reasoning)
            if isLastStep, !calls.isEmpty {
                // A call here will not be run. If that is all the model wrote, ask once more with the tools gone.
                calls = []
                if cleaned.text.isEmpty, !answerWithoutTools {
                    answerWithoutTools = true
                    continue
                }
                if cleaned.text.isEmpty { cleaned.text = "I ran out of steps before I could finish this." }
            }

            // A small model can spend its whole reply thinking and never answer.
            // Run the step once more with thinking off and more room, rather than
            // hand the user an empty turn.
            if calls.isEmpty, cleaned.text.isEmpty, stop == .length, !recoveredFromOverthinking {
                recoveredFromOverthinking = true
                carriedReasoning = cleaned.reasoning
                stepOptions.thinking = .off
                stepOptions.maxOutputTokens = options.maxOutputTokens * 2
                step -= 1
                continue
            }
            if !carriedReasoning.isEmpty {
                cleaned.reasoning = cleaned.reasoning.isEmpty ? carriedReasoning : carriedReasoning + "\n\n" + cleaned.reasoning
                carriedReasoning = ""
            }
            var assistant = Message.assistant(cleaned.text, toolCalls: calls)
            assistant.reasoning = cleaned.reasoning
            if !assistant.reasoning.isEmpty {
                assistant.reasoningSeconds = (reasoningEnded ?? Date()).timeIntervalSince(started)
            }
            assistant.stats = stats
            transcript.append(assistant)
            emit(.assistantMessage(assistant))

            if calls.isEmpty { return stop == .toolCalls ? .stop : stop }

            for call in calls {
                try Task.checkCancellation()
                let tool = toolsByName[call.name]
                let opensConnector = call.name == ToolGroup.openerName && !shelf.isEmpty
                let summary = opensConnector
                    ? "Opened \(shelf.group(named: call.arguments["connector"]?.stringValue ?? "")?.title ?? "a connector")"
                    : tool?.summary(for: call.arguments) ?? call.name
                emit(.toolStarted(call, summary: summary))

                let key = call.name + call.arguments.jsonString
                seenCalls[key, default: 0] += 1

                let result: ToolResult
                if call.name == ToolCall.unreadableName {
                    result = .error(
                        "Your tool call could not be read (\(call.arguments["reason"]?.stringValue ?? "bad format")). Write it again in exactly the required format, or answer without a tool.")
                } else if opensConnector {
                    let before = shelf.loaded
                    result = shelf.open(call.arguments, request: request)
                    if shelf.loaded != before { emit(.toolsLoaded(shelf.loaded)) }
                } else if let tool {
                    if seenCalls[key, default: 0] > 2 {
                        result = .error(
                            "You already made this exact call twice. Use the earlier result or answer now.")
                    } else {
                        // A connector tool called by name before it was opened is run
                        // anyway and declared from here on, along with the rest of its
                        // connector that fits the request. The model wrote that call
                        // without seeing the parameters, so a failure shows them.
                        let calledUnseen = shelf.use(call.name, request: request)
                        if calledUnseen { emit(.toolsLoaded(shelf.loaded)) }
                        var outcome = await tool.call(call.arguments)
                        if calledUnseen, outcome.isError {
                            outcome.text += "\nThis tool's parameters: " + Self.clip(tool.spec.parameters.jsonString, to: 2000)
                        }
                        result = outcome
                    }
                } else if let near = shelf.nearest(to: call.name) {
                    emit(.toolsLoaded(shelf.loaded))
                    result = .error(
                        "There is no tool named \(call.name). The closest \(near.title) tools, which you can call now: \(near.tools.joined(separator: ", ")).")
                } else {
                    let names = (alwaysDeclared + shelf.loadedSpecs).map(\.name).joined(separator: ", ")
                    result = .error(
                        "There is no tool named \(call.name). Available tools: \(names.isEmpty ? "none" : names).")
                }

                var text = ResultFit.fit(result.text, limit: maxToolResultCharacters)
                // The same answer to a different question means the change made no
                // difference. Saying so takes a line; repeating it takes the whole
                // result again and invites another try.
                let fingerprint = call.name + "\u{0}" + text
                if !result.isError, text.count > 400, seenResults.contains(fingerprint) {
                    text = "This is the same result as an earlier \(call.name) call in this turn, so changing the arguments that way made no difference. "
                        + "Use the earlier result, or change a different argument."
                } else {
                    seenResults.insert(fingerprint)
                }
                // A result that names a connector's tool, as a skill's instructions do, brings that tool in.
                // Not the opener's own result, which lists what it left out.
                if !result.isError, call.name != ToolGroup.openerName, shelf.loadNamed(in: text, request: request) {
                    emit(.toolsLoaded(shelf.loaded))
                }
                let message = Message.tool(text, call: call, isError: result.isError)
                transcript.append(message)
                emit(.toolFinished(message))
            }
        }
        return .stop
    }

    static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n[Result cut off at \(limit) characters.]"
    }
}

/// Keeps a transcript inside an approximate token budget.
public enum ContextBudget {
    /// Rough token estimate. Good enough for budgeting without a tokenizer.
    public static func estimateTokens(_ text: String) -> Int {
        max(1, text.utf8.count / 4)
    }

    public static func estimateTokens(_ message: Message) -> Int {
        var total = estimateTokens(message.text) + 4
        for call in message.toolCalls {
            total += estimateTokens(call.name) + estimateTokens(call.arguments.jsonString) + 8
        }
        total += message.images.count * 256
        return total
    }

    /// Returns a transcript that fits the budget. Old tool results are shortened
    /// first because they are the bulkiest and least useful once answered; whole
    /// old turns are dropped only if that is not enough. The system prompt and
    /// the latest user turn always survive.
    public static func fit(_ messages: [Message], budgetTokens: Int) -> [Message] {
        func total(_ list: [Message]) -> Int { list.reduce(0) { $0 + estimateTokens($1) } }
        guard total(messages) > budgetTokens else { return messages }

        var result = messages
        let lastUserIndex = result.lastIndex { $0.role == .user } ?? 0

        for index in result.indices where index < lastUserIndex && result[index].role == .tool {
            if result[index].text.count > 200 {
                result[index].text = String(result[index].text.prefix(200)) + " [older result shortened]"
            }
            if total(result) <= budgetTokens { return result }
        }

        // Drop the oldest turns that come before the latest user message.
        var firstKept = result.firstIndex { $0.role != .system } ?? 0
        while total(result) > budgetTokens, firstKept < lastUserIndex {
            // Remove one whole turn: a user message and everything up to the next user message.
            var end = firstKept + 1
            while end < lastUserIndex, result[end].role != .user { end += 1 }
            result.removeSubrange(firstKept..<end)
            let removed = end - firstKept
            firstKept = result.firstIndex { $0.role != .system } ?? 0
            if removed == 0 { break }
            let newLastUser = result.lastIndex { $0.role == .user } ?? 0
            if firstKept >= newLastUser { break }
        }
        return result
    }
}
