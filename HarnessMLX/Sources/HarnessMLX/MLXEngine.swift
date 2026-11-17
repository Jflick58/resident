import CoreImage
import Foundation
import HarnessKit
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

/// Owns the one model loaded in memory and the chat session that carries its
/// key-value cache between agent steps.
///
/// The harness sends a full transcript on every step. Re-reading it from the
/// start each time would make every tool call cost seconds, so the engine keeps
/// a `ChatSession` and feeds it only the messages it has not seen. When a
/// request does not extend the last one (a different chat, an edited or trimmed
/// transcript, changed settings) the session is rebuilt from the transcript.
public actor MLXEngine {
    public static let shared = MLXEngine()

    private var container: ModelContainer?
    private var loadedDirectory: URL?

    private var session: ChatSession?
    private var sessionKey: SessionKey?
    /// IDs of the transcript messages the session's cache represents, in order.
    private var sessionMessageIDs: [Mark] = []

    /// A transcript message as the session knows it. The size is part of it
    /// because the agent shortens old tool results between turns: the same
    /// message with different text is not what the cache holds.
    private struct Mark: Equatable {
        var id: UUID
        var size: Int

        init(_ message: HarnessKit.Message) {
            id = message.id
            size = message.text.utf8.count
        }
    }

    private struct SessionKey: Equatable {
        var instructions: String
        var tools: String
        var callable: String
        var thinking: ThinkingLevel
        var maxOutputTokens: Int
        var temperature: Double
        var topP: Double
        var repetitionPenalty: Double?
        var contextTokens: Int
    }

    public init() {}

    /// Whether tool calls are held to valid syntax by a grammar. See ``ToolCallGrammar``.
    public var constrainsToolCalls = true

    public func setConstrainsToolCalls(_ value: Bool) {
        constrainsToolCalls = value
        session = nil
        sessionKey = nil
    }

    /// For self-checks only: build the grammar from these tools instead of the ones
    /// shown to the model, so a test can tell the grammar's effect from the model's.
    public func setGrammarToolsForTesting(_ tools: [HarnessKit.ToolSpec]?) {
        grammarToolsOverride = tools
        session = nil
        sessionKey = nil
    }

    private var grammarToolsOverride: [HarnessKit.ToolSpec]?

    public var loadedModelDirectory: URL? { loadedDirectory }

    /// Loads the model in `directory`, replacing any model already loaded.
    public func load(directory: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if loadedDirectory == directory, container != nil { return }
        unload()
        let handlers = LoadProgressHandlers(weights: { value in progress?(value.fractionCompleted) })
        let loaded = try await loadModelContainer(
            from: directory, using: #huggingFaceTokenizerLoader(), progress: handlers)
        container = loaded
        loadedDirectory = directory
    }

    public func unload() {
        // Nothing loaded means MLX was never started; leave it that way. Touching it
        // would also abort in the simulator, where there is no Metal device for it.
        guard container != nil else { return }
        session = nil
        opening = nil
        openingKey = nil
        sessionKey = nil
        sessionMessageIDs = []
        container = nil
        loadedDirectory = nil
        MLX.Memory.clearCache()
    }

    public nonisolated func provider(contextTokens: Int = 8192) -> MLXProvider {
        MLXProvider(engine: self, contextTokens: contextTokens)
    }

    // MARK: Generation

    func generate(
        _ request: GenerationRequest, contextTokens: Int,
        continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation
    ) async throws {
        guard let container else {
            throw ProviderError("No model is loaded.")
        }

        let instructions = request.messages.first { $0.role == .system }?.text ?? ""
        let transcript = request.messages.filter { $0.role != .system }
        guard !transcript.isEmpty else { throw ProviderError("There is nothing to respond to.") }

        let key = SessionKey(
            instructions: instructions,
            tools: JSONValue.array(request.tools.map(\.functionDeclaration)).jsonString,
            callable: JSONValue.array((request.callableTools ?? []).map(\.functionDeclaration)).jsonString,
            thinking: request.options.thinking, maxOutputTokens: request.options.maxOutputTokens,
            temperature: request.options.temperature, topP: request.options.topP,
            repetitionPenalty: request.options.repetitionPenalty, contextTokens: contextTokens)

        // Messages the model has not answered yet: everything after the last assistant message.
        let pendingStart = (transcript.lastIndex { $0.role == .assistant }).map { $0 + 1 } ?? 0
        let ids = transcript.map(Mark.init)

        let activeSession: ChatSession
        let newMessages: [HarnessKit.Message]
        if let session, sessionKey == key, !sessionMessageIDs.isEmpty,
            ids.count > sessionMessageIDs.count, Array(ids.prefix(sessionMessageIDs.count)) == sessionMessageIDs
        {
            // The request extends what the session already holds: reuse its cache.
            activeSession = session
            newMessages = Array(transcript[sessionMessageIDs.count...])
        } else {
            if ProcessInfo.processInfo.environment["HARNESS_DEBUG_SESSION"] != nil {
                // Development aid: why the cache could not be carried on.
                let prefixMatches = Array(ids.prefix(sessionMessageIDs.count)) == sessionMessageIDs
                var changed: [String] = []
                if let old = sessionKey {
                    if old.instructions != key.instructions { changed.append("instructions") }
                    if old.tools != key.tools { changed.append("tools") }
                    if old.callable != key.callable { changed.append("callable") }
                    if old.thinking != key.thinking { changed.append("thinking") }
                    if old.maxOutputTokens != key.maxOutputTokens { changed.append("maxOutputTokens") }
                    if old.temperature != key.temperature || old.topP != key.topP { changed.append("sampling") }
                }
                FileHandle.standardError.write(
                    "NEW SESSION had=\(session != nil) changed=\(changed) known=\(sessionMessageIDs.count) ids=\(ids.count) prefix=\(prefixMatches)\n"
                        .data(using: .utf8)!)
            }
            let history = try transcript[..<pendingStart].map(Self.chatMessage)
            let fresh = try await makeSession(container: container, key: key, request: request, history: history)
            // A new chat starts the same way as the last one: the same instructions and tools,
            // some 2,000 tokens that a large model takes most of a minute to read. So that
            // opening is read once into a session of its own, and each chat starts from a copy
            // of it and reads only what follows. The opening is kept beside the model, so the
            // next run does not read it either.
            if openingKey != key {
                // Tools declared part-way through a chat change the prompt from its start. An opening
                // for them is used if there is one, but only the start of a chat is worth making one for.
                var found = await savedOpening(container: container, like: fresh, key: key)
                if found == nil, history.isEmpty,
                    let made = try? await makeSession(container: container, key: key, request: request, history: []),
                    (try? await made.readSharedOpening()) != nil
                {
                    found = made
                    await saveOpening(made, key: key)
                }
                if let found {
                    opening = found
                    openingKey = key
                }
            }
            if let opening, openingKey == key {
                let forked = await opening.fork(history: history)
                forked.instructions = fresh.instructions
                forked.generateParameters = fresh.generateParameters
                forked.components = fresh.components
                forked.processing = fresh.processing
                forked.additionalContext = fresh.additionalContext
                forked.tools = fresh.tools
                activeSession = forked
            } else {
                activeSession = fresh
            }
            session = activeSession
            sessionKey = key
            newMessages = Array(transcript[pendingStart...])
        }
        guard !newMessages.isEmpty else {
            throw ProviderError("The last message in the conversation is already answered.")
        }

        // Until the turn completes the session's state is unknown; a cancelled
        // or failed turn must not be extended.
        sessionMessageIDs = []

        var sawToolCall = false
        var sawRejection = false
        var stats: GenerationStats?
        var stop = StopReason.stop
        let started = Date()
        var firstToken: Date?

        _ = MLXFailure.install
        _ = MLXFailure.take()
        let stream = activeSession.streamDetails(to: try newMessages.map(Self.chatMessage))
        do {
            for try await event in stream {
                try Task.checkCancellation()
                // After an MLX error the stream carries on with nonsense; stop at the first sign.
                if let failure = MLXFailure.take() { throw ModelStoppedError(failure) }
                switch event {
                case .chunk(let text):
                    if firstToken == nil { firstToken = Date() }
                    continuation.yield(.text(text))
                case .reasoning(let text):
                    if firstToken == nil { firstToken = Date() }
                    continuation.yield(.reasoning(text))
                case .toolCall(let call):
                    sawToolCall = true
                    continuation.yield(.toolCall(Self.toolCall(call)))
                case .rejectedToolCall(let rejection):
                    // The library drops calls it cannot use. Hand them to the agent
                    // instead, so the model gets an error it can react to.
                    sawToolCall = true
                    sawRejection = true
                    if ProcessInfo.processInfo.environment["HARNESS_DEBUG_REJECTED"] != nil {
                        // Development aid: show what the model wrote. Never on by default, since it can hold user data.
                        FileHandle.standardError.write(
                            "REJECTED \(rejection.reason.rawValue) [\(rejection.format)]: \(rejection.rawTextPreview)\n".data(using: .utf8)!)
                    }
                    continuation.yield(.toolCall(Self.recover(rejection)))
                case .info(let info):
                    stats = GenerationStats(
                        promptTokens: info.promptTokenCount, outputTokens: info.generationTokenCount,
                        tokensPerSecond: info.tokensPerSecond,
                        timeToFirstToken: firstToken.map { $0.timeIntervalSince(started) })
                    if ProcessInfo.processInfo.environment["HARNESS_DEBUG_SESSION"] != nil {
                        FileHandle.standardError.write(
                            String(format: "STEP read %d tokens, first token after %.2fs, prompt time %.2fs\n", info.promptTokenCount,
                                firstToken.map { $0.timeIntervalSince(started) } ?? -1, info.promptTime).data(using: .utf8)!)
                    }
                    switch info.stopReason {
                    case .length: stop = .length
                    case .cancelled: stop = .cancelled
                    default: stop = .stop
                    }
                case .steering:
                    break
                }
            }
        } catch {
            session = nil
            sessionKey = nil
            throw error
        }
        if let failure = MLXFailure.take() {
            session = nil
            opening = nil
            sessionKey = nil
            throw ModelStoppedError(failure)
        }

        // The session now also holds the assistant reply the caller is about to
        // append. That message's ID is not known here, so remember the transcript
        // up to it and treat one more message as covered.
        if sawRejection {
            // The session does not keep a turn whose call it rejected, so its cache
            // no longer matches the transcript. Rebuild from the transcript next time.
            session = nil
            sessionKey = nil
        } else {
            sessionMessageIDs = ids
            pendingAssistant = true
        }
        continuation.yield(.finished(sawToolCall ? .toolCalls : stop, stats))
    }

    // MARK: The opening of a chat, kept between chats and between runs

    /// A session whose cache holds what every chat with `openingKey` starts with, and nothing else.
    private var opening: ChatSession?
    private var openingKey: SessionKey?
    /// Openings kept beside a model: one for each set of instructions and tools, the newest few.
    static let savedOpenings = 3
    private static func savedOpeningName(_ key: SessionKey) -> String { "prompt-cache-\(fingerprint(key)).safetensors" }

    /// A mark of everything the opening's tokens depend on, to tell whether a saved one still fits.
    private static func fingerprint(_ key: SessionKey) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(key.instructions)|\(key.tools)|\(key.thinking)|\(key.contextTokens)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    /// The opening saved beside the loaded model for these instructions and tools, if there is one.
    private func savedOpening(container: ModelContainer, like fresh: ChatSession, key: SessionKey) async -> ChatSession? {
        guard let url = loadedDirectory?.appendingPathComponent(Self.savedOpeningName(key)),
            FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        guard let snapshot = try? loadPromptCacheSnapshot(url: url),
            let saved = ChatSession(container, savedCache: snapshot, generateParameters: fresh.generateParameters)
        else {
            // Written by another version, or cut short: of no use, and it would be read again every time.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        // Used now, so it outlasts the ones that are not.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return saved
    }

    private func saveOpening(_ session: ChatSession, key: SessionKey) async {
        guard let directory = loadedDirectory else { return }
        let final = directory.appendingPathComponent(Self.savedOpeningName(key))
        let partial = directory.appendingPathComponent("partial-" + final.lastPathComponent)
        do {
            guard try await session.saveCacheWithTokens(to: partial) != nil else { return }
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: partial, to: final)
        } catch {
            try? FileManager.default.removeItem(at: partial)
        }
        // The prompt changes with the day, the user's memory and their connectors: old openings go.
        let saved = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("prompt-cache") }
            .sorted {
                let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return first > second
            }
        for old in saved.dropFirst(Self.savedOpenings) { try? FileManager.default.removeItem(at: old) }
    }

    /// True when the session holds an assistant reply whose transcript ID has not been seen yet.
    private var pendingAssistant = false

    /// Called at the start of a request to fold the previous reply's ID into the known prefix.
    private func adoptPendingAssistant(from ids: [Mark], roles: [Role]) {
        guard pendingAssistant else { return }
        pendingAssistant = false
        let index = sessionMessageIDs.count
        if index < ids.count, roles[index] == .assistant,
            Array(ids.prefix(index)) == sessionMessageIDs
        {
            sessionMessageIDs.append(ids[index])
        } else {
            sessionMessageIDs = []
        }
    }

    func run(
        _ request: GenerationRequest, contextTokens: Int,
        continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation
    ) async {
        let transcript = request.messages.filter { $0.role != .system }
        adoptPendingAssistant(from: transcript.map(Mark.init), roles: transcript.map(\.role))
        do {
            try await generate(request, contextTokens: contextTokens, continuation: continuation)
            continuation.finish()
        } catch is CancellationError {
            session = nil
            sessionKey = nil
            continuation.finish(throwing: CancellationError())
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func makeSession(
        container: ModelContainer, key: SessionKey, request: GenerationRequest, history: [Chat.Message]
    ) async throws -> ChatSession {
        var parameters = GenerateParameters(
            maxTokens: request.options.maxOutputTokens, maxKVSize: key.contextTokens,
            temperature: Float(request.options.temperature), topP: Float(request.options.topP))
        parameters.repetitionPenalty = request.options.repetitionPenalty.map(Float.init)

        // Thinking on or off, expressed the way this model's chat template expects.
        let reasoning = await container.configuration.reasoningConfig
        var context: [String: any Sendable]?
        if let reasoning {
            context = try? reasoning.promptStrategy.additionalContext(
                forThinkingEnabled: request.options.thinking != .off)
        }

        var components = GenerationComponents()

        // Hold tool calls to valid syntax, for models that write them as tagged JSON.
        let format = await container.configuration.toolCallFormat
        let callable = request.callableTools ?? request.tools
        if constrainsToolCalls, !callable.isEmpty, format == nil || format == .json {
            let tokenizer = await container.tokenizer
            components.logitProcessorFactory = ToolCallGrammar.processorFactory(
                tools: grammarToolsOverride ?? callable, tokenizer: tokenizer)
        }

        // Cap thinking for the lower levels so a small model cannot spend the whole reply on it.
        if let reasoning, let budget = request.options.thinking.tokenBudget, budget > 0,
            budget + 256 < request.options.maxOutputTokens
        {
            let tokenizer = await container.tokenizer
            if let configuration = try? ThinkingBudgetConfiguration(
                maximumTokenCount: budget, minimumAnswerTokenCount: 128),
                let limited = try? components.applyingThinkingBudget(
                    configuration, reasoning: reasoning, tokenizer: tokenizer)
            {
                components = limited
            }
        }

        // Last, around whatever is already there: the gate that holds generation while the app is off screen.
        let existing = components.logitProcessorFactory
        components.logitProcessorFactory = { GatedProcessor(inner: existing?()) }

        let tools: [MLXLMCommon.ToolSpec]? = request.tools.isEmpty ? nil : request.tools.map(Self.toolSpec)
        return ChatSession(
            container, instructions: key.instructions.isEmpty ? nil : key.instructions, history: history,
            generateParameters: parameters, components: components,
            processing: .init(resize: CGSize(width: 768, height: 768)), additionalContext: context,
            tools: tools)
    }

    // MARK: Conversions

    static func chatMessage(_ message: HarnessKit.Message) throws -> Chat.Message {
        switch message.role {
        case .system:
            return .system(message.text)
        case .user:
            let images = message.images.compactMap { attachment -> UserInput.Image? in
                CIImage(data: attachment.data).map { .ciImage($0) }
            }
            return .user(message.text, images: images)
        case .assistant:
            let calls = message.toolCalls.map { call in
                MLXLMCommon.ToolCall(
                    function: .init(name: call.name, arguments: Self.arguments(call.arguments)), id: call.id)
            }
            return .assistant(message.text, toolCalls: calls.isEmpty ? nil : calls)
        case .tool:
            return .tool(message.text, id: message.toolCallID, name: message.toolName)
        }
    }

    static func arguments(_ value: HarnessKit.JSONValue) -> [String: MLXLMCommon.JSONValue] {
        guard case .object(let object) = value else { return [:] }
        return object.mapValues(convert)
    }

    static func convert(_ value: HarnessKit.JSONValue) -> MLXLMCommon.JSONValue {
        switch value {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .int(let value): return .int(value)
        case .double(let value): return .double(value)
        case .string(let value): return .string(value)
        case .array(let value): return .array(value.map(convert))
        case .object(let value): return .object(value.mapValues(convert))
        }
    }

    static func convert(_ value: MLXLMCommon.JSONValue) -> HarnessKit.JSONValue {
        switch value {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .int(let value): return .int(value)
        case .double(let value): return .double(value)
        case .string(let value): return .string(value)
        case .array(let value): return .array(value.map(convert))
        case .object(let value): return .object(value.mapValues(convert))
        }
    }

    /// Turns a rejected call back into something the agent can act on: the call
    /// itself when it can be read, otherwise an unreadable call the agent
    /// answers with an error.
    static func recover(_ rejection: RejectedToolCall) -> HarnessKit.ToolCall {
        // Parse again without the library's list of declared tools. Some of its
        // parsers report a well-formed call to an unlisted tool as malformed, so
        // this is tried whatever the stated reason.
        if !rejection.isPreviewTruncated {
            let processor = ToolCallProcessor(format: rejection.format, tools: nil)
            _ = processor.processChunk(rejection.rawTextPreview)
            _ = processor.processEOS(returnBufferedText: false)
            if let call = processor.toolCalls.first { return toolCall(call) }
        }
        if rejection.reason == .undeclaredTool, let name = rejection.toolName {
            return HarnessKit.ToolCall(name: name, arguments: [:])
        }
        return .unreadable(reason: rejection.reason.rawValue.replacingOccurrences(of: "_", with: " "))
    }

    static func toolCall(_ call: MLXLMCommon.ToolCall) -> HarnessKit.ToolCall {
        HarnessKit.ToolCall(
            id: call.id ?? HarnessKit.ToolCall.makeID(), name: call.function.name,
            arguments: .object(call.function.arguments.mapValues(convert)))
    }

    static func toolSpec(_ spec: HarnessKit.ToolSpec) -> MLXLMCommon.ToolSpec {
        sendable(spec.functionDeclaration) as? MLXLMCommon.ToolSpec ?? [:]
    }

    static func sendable(_ value: HarnessKit.JSONValue) -> any Sendable {
        switch value {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(sendable)
        case .object(let value): return value.mapValues(sendable) as [String: any Sendable]
        }
    }
}

/// The on-device model as a harness provider.
public struct MLXProvider: ModelProvider {
    let engine: MLXEngine
    let contextTokens: Int

    public func generate(_ request: GenerationRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await engine.run(request, contextTokens: contextTokens, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
