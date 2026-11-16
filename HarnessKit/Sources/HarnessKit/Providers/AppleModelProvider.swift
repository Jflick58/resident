#if canImport(FoundationModels)
    import Foundation
    import FoundationModels

    /// The model built into the system (Apple Intelligence), behind the same
    /// interface as the others.
    ///
    /// Nothing is downloaded and nothing is loaded into this app's memory: the
    /// system runs the model in its own process. That also means it can answer
    /// while the app is not on screen, which a model run by the app cannot.
    ///
    /// The framework wants to run tools itself. The agent loop here needs to run
    /// them, because that is where tool search, result fitting and the rest of
    /// the harness live. So each step is a fresh session built from the
    /// transcript, and a tool call is caught on its way out: the stand-in tool
    /// records the call and stops the response, the agent runs the real tool,
    /// and the next step's transcript carries the result.
    @available(iOS 26.0, macOS 26.0, *)
    public struct AppleModelProvider: ModelProvider {
        public init() {}

        /// Why the system model cannot be used, or nil when it can.
        public static var unavailableReason: String? {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "This device does not support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in Settings to use it here."
            case .unavailable(.modelNotReady): return "Apple Intelligence is still getting ready. Try again in a while."
            case .unavailable: return "Apple Intelligence is not available."
            }
        }

        /// How long one step may take before it is given up on.
        static let patienceSeconds = 90

        static let carryOn =
            "(The tool results are above. Carry on: answer the user, or call another tool only if the request still needs one.)"

        /// How many tokens the system model can take in one go.
        public static var contextTokens: Int { SystemLanguageModel.default.contextSize }

        public func generate(_ request: GenerationRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        // The system model has been seen to stop answering part-way through a
                        // run of requests, with no error. Better an error than a chat that never ends.
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            group.addTask { try await Self.run(request, continuation: continuation) }
                            group.addTask {
                                try await Task.sleep(for: .seconds(Self.patienceSeconds))
                                throw ProviderError("Apple Intelligence did not answer. Try again, or use another model.")
                            }
                            try await group.next()
                            group.cancelAll()
                        }
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        private static func run(
            _ request: GenerationRequest, continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation
        ) async throws {
            if let reason = unavailableReason { throw ProviderError(reason) }
            let caught = CaughtCalls()
            // Given tools, this model calls one as its first move whatever is asked:
            // "write a story" became a web search, or code that printed an excuse
            // (8 tries in 8). So a new request is first sorted into one that needs
            // tools and one to answer directly, and the second kind gets no tools.
            var specs = request.tools
            var messages = request.messages
            if !specs.isEmpty, let last = messages.last, last.role == .user, await Self.answersDirectly(last.text) {
                specs = []
                // And instructions that say nothing of tools: told about memory and
                // skills it cannot reach, the model reports having used them.
                if let plain = request.plainInstructions {
                    messages = [.system(plain)] + messages.filter { $0.role != .system }
                }
            }
            let tools: [any FoundationModels.Tool] = try specs.map { spec in
                StandInTool(
                    name: spec.name, description: spec.description,
                    parameters: try GenerationSchema(root: Self.schema(spec.parameters, name: spec.name), dependencies: []),
                    caught: caught)
            }

            var entries = try Self.entries(for: messages, tools: tools)
            // The message being answered is given as the prompt. After a tool result
            // there is none to give, and the framework still wants one. Given an
            // empty prompt the model takes it for a new, blank request and makes
            // something up to do (it invented facts to save, 7 tries in 8); told
            // plainly to carry on, it answers (4 in 4).
            var prompt = Self.carryOn
            if case .prompt(let last) = entries.last, messages.last?.role == .user {
                prompt = messages.last?.text ?? ""
                entries.removeLast()
                _ = last
            }
            let session = LanguageModelSession(model: .default, tools: tools, transcript: Transcript(entries: entries))
            let options = FoundationModels.GenerationOptions(
                temperature: request.options.temperature, maximumResponseTokens: request.options.maxOutputTokens)

            let started = Date()
            var firstToken: Date?
            var written = ""
            do {
                for try await snapshot in session.streamResponse(to: prompt, options: options) {
                    try Task.checkCancellation()
                    let text = snapshot.content
                    guard text.count > written.count, text.hasPrefix(written) else {
                        written = text
                        continue
                    }
                    if firstToken == nil { firstToken = Date() }
                    continuation.yield(.text(String(text.dropFirst(written.count))))
                    written = text
                }
            } catch let error as LanguageModelSession.ToolCallError where error.underlyingError is CaughtCalls.Stop {
                // A tool call on its way out: hand it to the agent.
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .exceededContextWindowSize:
                    throw ProviderError("This chat is too long for Apple Intelligence, which takes about \(contextTokens) tokens. Start a new chat or use another model.")
                case .guardrailViolation:
                    throw ProviderError("Apple Intelligence declined to answer that.")
                default:
                    throw ProviderError("Apple Intelligence could not answer: \(error.localizedDescription)")
                }
            }

            let calls = caught.calls
            for call in calls { continuation.yield(.toolCall(call)) }
            let seconds = Date().timeIntervalSince(firstToken ?? started)
            let outputTokens = max(1, written.utf8.count / 4)
            continuation.yield(
                .finished(
                    calls.isEmpty ? .stop : .toolCalls,
                    GenerationStats(
                        outputTokens: outputTokens, tokensPerSecond: seconds > 0.05 ? Double(outputTokens) / seconds : nil,
                        timeToFirstToken: firstToken.map { $0.timeIntervalSince(started) })))
        }

        // MARK: Routing

        static let routingInstructions = """
            An assistant has tools for: searching the web, reading a web page, running calculations, saving facts about the user, \
            and reaching the user's calendar, reminders and work apps.
            Reply "tools" if the request below needs any of those. Reply "direct" if the assistant should simply write the \
            answer itself, which is the case for stories, poems, explanations, well-known facts, advice, translation, rewriting and small talk.

            Examples:
            Write a poem about autumn -> direct
            What's the weather in Paris today? -> tools
            Explain photosynthesis -> direct
            What is 48 * 392? -> tools
            Hello -> direct
            Do I have meetings today? -> tools
            Remember that I prefer short answers -> tools
            Give me tips for a job interview -> direct
            Tell me a story about a dragon -> direct
            Who is the president of France right now? -> tools
            What is the tallest mountain in the world? -> direct
            Make it shorter -> direct
            Summarise https://example.org/article -> tools
            How does a car engine work? -> direct
            Write a long essay about the ocean -> direct
            Can you make it more formal? -> direct
            """

        /// Whether a request is one to answer without tools. One short question to
        /// the model, answered from a choice of two words, in about half a second.
        /// On 34 requests it was right on 32 and its two mistakes both kept the
        /// tools; it never took them from a request that needed them. In doubt, tools stay.
        static func answersDirectly(_ request: String) async -> Bool {
            guard let schema = try? GenerationSchema(root: DynamicGenerationSchema(name: "choice", anyOf: ["direct", "tools"]), dependencies: [])
            else { return false }
            let session = LanguageModelSession(model: .default, instructions: routingInstructions)
            let options = FoundationModels.GenerationOptions(temperature: 0)
            guard let reply = try? await session.respond(to: "Request: " + String(request.prefix(600)), schema: schema, options: options)
            else { return false }
            return (try? reply.content.value(String.self)) == "direct"
        }

        // MARK: Transcript

        private static func text(_ string: String) -> Transcript.Segment { .text(.init(content: string)) }

        /// The conversation so far in the framework's own form.
        private static func entries(for messages: [Message], tools: [any FoundationModels.Tool]) throws -> [Transcript.Entry] {
            var entries: [Transcript.Entry] = []
            let system = messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
            entries.append(.instructions(.init(segments: [text(system)], toolDefinitions: tools.map { .init(tool: $0) })))
            for message in messages {
                switch message.role {
                case .system:
                    continue
                case .user:
                    entries.append(.prompt(.init(segments: [text(message.text)])))
                case .assistant:
                    if !message.toolCalls.isEmpty {
                        let calls = try message.toolCalls.map { call in
                            Transcript.ToolCall(
                                id: call.id, toolName: call.name, arguments: try GeneratedContent(json: call.arguments.jsonString))
                        }
                        entries.append(.toolCalls(.init(calls)))
                    } else if !message.text.isEmpty {
                        entries.append(.response(.init(assetIDs: [], segments: [text(message.text)])))
                    }
                case .tool:
                    entries.append(
                        .toolOutput(.init(id: message.toolCallID ?? UUID().uuidString, toolName: message.toolName ?? "tool", segments: [text(message.text)])))
                }
            }
            return entries
        }

        // MARK: Schemas

        /// A tool's JSON Schema in the framework's form. What it cannot express is taken as text.
        static func schema(_ value: JSONValue, name: String) -> DynamicGenerationSchema {
            let description = value["description"]?.stringValue
            if let options = value["enum"]?.arrayValue?.compactMap(\.stringValue), !options.isEmpty {
                return DynamicGenerationSchema(name: name, description: description, anyOf: options)
            }
            switch value["type"]?.stringValue {
            case "object":
                let required = Set(value["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                let properties = (value["properties"]?.objectValue ?? [:]).sorted { $0.key < $1.key }.map { key, property in
                    DynamicGenerationSchema.Property(
                        name: key, description: property["description"]?.stringValue,
                        schema: schema(property, name: "\(name)_\(key)"), isOptional: !required.contains(key))
                }
                return DynamicGenerationSchema(name: name, description: description, properties: properties)
            case "array":
                return DynamicGenerationSchema(arrayOf: value["items"].map { schema($0, name: "\(name)_item") } ?? DynamicGenerationSchema(type: String.self))
            case "integer": return DynamicGenerationSchema(type: Int.self)
            case "number": return DynamicGenerationSchema(type: Double.self)
            case "boolean": return DynamicGenerationSchema(type: Bool.self)
            default: return DynamicGenerationSchema(type: String.self)
            }
        }
    }

    /// Tool calls the model made in one step, caught before the framework could run them.
    @available(iOS 26.0, macOS 26.0, *)
    private final class CaughtCalls: @unchecked Sendable {
        struct Stop: Error {}
        private let lock = NSLock()
        private var recorded: [ToolCall] = []

        var calls: [ToolCall] { lock.withLock { recorded } }

        func record(name: String, arguments: GeneratedContent) {
            let value = JSONValue(jsonString: arguments.jsonString) ?? .object([:])
            lock.withLock { recorded.append(ToolCall(name: name, arguments: value)) }
        }
    }

    /// Stands where a real tool would in the framework's session.
    @available(iOS 26.0, macOS 26.0, *)
    private struct StandInTool: FoundationModels.Tool {
        let name: String
        let description: String
        let parameters: GenerationSchema
        let caught: CaughtCalls

        func call(arguments: GeneratedContent) async throws -> String {
            caught.record(name: name, arguments: arguments)
            // Calls made together arrive together: give the others a moment to be caught too.
            try await Task.sleep(for: .milliseconds(150))
            throw CaughtCalls.Stop()
        }
    }
#endif
