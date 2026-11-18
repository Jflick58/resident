import CoreImage
import Foundation
import HarnessKit
import os
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
    /// True when the loaded model's weights are mapped and take more than half of the device's memory.
    private var loadedFillsMemory = false

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
        /// How the cache is stored and the prompt read: a session made under one setting is not used under another.
        var tuning: String

        /// True when only the tools differ.
        func matchesButForTools(_ other: SessionKey) -> Bool {
            var copy = other
            copy.tools = tools
            copy.callable = callable
            return copy == self
        }
    }

    /// Names of the tools the session's prompt declared at its start.
    private var sessionTemplateTools: Set<String> = []
    /// Tools the session's model was told of later, in the conversation. See `declaresToolsLate`.
    private var sessionLaterTools: [String: HarnessKit.ToolSpec] = [:]

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
        // A ternary model that fills the device's memory is computed without reading the tenth
        // of its weights that repeats another tenth. It costs a few per cent of speed, which is
        // worth it only where every token would otherwise wait on storage.
        switch ProcessInfo.processInfo.environment["HARNESS_SHARE_SCALES"] {
        case "1", "check": HadamardQuantizedLinear.sharesScales = true
        case "0": HadamardQuantizedLinear.sharesScales = false
        default: HadamardQuantizedLinear.sharesScales = Self.mapsWeights && Self.fillsMemory(directory)
        }
        loadedFillsMemory = Self.mapsWeights && Self.fillsMemory(directory)
        let handlers = LoadProgressHandlers(weights: { value in progress?(value.fractionCompleted) })
        let started = Date()
        let loaded = try await loadModelContainer(
            from: directory, using: #huggingFaceTokenizerLoader(), progress: handlers)
        container = loaded
        loadedDirectory = directory
        Self.note(String(format: "loaded %@ in %.1fs", directory.lastPathComponent, Date().timeIntervalSince(started)))
    }

    /// True when the model's weights take more than half of the device's memory.
    nonisolated static func fillsMemory(_ directory: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let weights = files.filter { $0.pathExtension == "safetensors" && !$0.lastPathComponent.hasPrefix("prompt-cache") }
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return UInt64(weights) * 2 > ProcessInfo.processInfo.physicalMemory
    }

    public func unload() {
        // Nothing loaded means MLX was never started; leave it that way. Touching it
        // would also abort in the simulator, where there is no Metal device for it.
        guard container != nil else { return }
        session = nil
        sessionKey = nil
        sessionMessageIDs = []
        container = nil
        loadedDirectory = nil
        loadedFillsMemory = false
        HadamardQuantizedLinear.forgetRotations()
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

        if request.options.standsAlone == true {
            try await answerAlone(request, instructions: instructions, transcript: transcript, contextTokens: contextTokens, continuation: continuation)
            return
        }

        let key = SessionKey(
            instructions: instructions,
            tools: JSONValue.array(request.tools.map(\.functionDeclaration)).jsonString,
            callable: JSONValue.array((request.callableTools ?? []).map(\.functionDeclaration)).jsonString,
            thinking: request.options.thinking, maxOutputTokens: request.options.maxOutputTokens,
            temperature: request.options.temperature, topP: request.options.topP,
            repetitionPenalty: request.options.repetitionPenalty, contextTokens: contextTokens, tuning: Self.tuningName)

        // Messages the model has not answered yet: everything after the last assistant message.
        let pendingStart = (transcript.lastIndex { $0.role == .assistant }).map { $0 + 1 } ?? 0
        let ids = transcript.map(Mark.init)

        let activeSession: ChatSession
        var newMessages: [HarnessKit.Message]
        let extends = !sessionMessageIDs.isEmpty && ids.count > sessionMessageIDs.count
            && Array(ids.prefix(sessionMessageIDs.count)) == sessionMessageIDs
        if let session, sessionKey == key, extends {
            // The request extends what the session already holds: reuse its cache.
            activeSession = session
            newMessages = Array(transcript[sessionMessageIDs.count...])
        } else if let session, let old = sessionKey, extends, Self.declaresToolsLate, old.matchesButForTools(key) {
            // Only the tools changed: a connector was opened part-way through the chat. The
            // template declares tools at the very start of the prompt, so declaring the new ones
            // there would change the prompt from its first tokens, and a model whose cache cannot
            // be rewound would read all of it again: 5,400 tokens when the code tools open, two
            // minutes for a 27B on a phone, and again at each tool added after. So the session
            // keeps the prompt it has, and the new tools are declared where the conversation
            // stands, after the message that brought them.
            let added = request.tools.filter { !sessionTemplateTools.contains($0.name) && sessionLaterTools[$0.name] == nil }
            for tool in added { sessionLaterTools[tool.name] = tool }
            // A tool dropped from the list stays known to the session: the model still sees it
            // declared, and a call to it should reach the agent, which knows what to do with it.
            session.laterTools = sessionLaterTools.keys.sorted().compactMap { sessionLaterTools[$0] }.map(Self.toolSpec)
            session.components = await components(container: container, request: request)
            activeSession = session
            sessionKey = key
            newMessages = Array(transcript[sessionMessageIDs.count...])
            if !added.isEmpty, let last = newMessages.indices.last, newMessages[last].role == .tool || newMessages[last].role == .user {
                newMessages[last].text += Self.declarations(added)
            }
            if ProcessInfo.processInfo.environment["HARNESS_DEBUG_SESSION"] != nil {
                FileHandle.standardError.write("LATE TOOLS added=\(added.map(\.name))\n".data(using: .utf8)!)
            }
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
            // The opening is not kept in memory between chats. A copy shares its arrays with the
            // original, so while the original lives, the chat's first write copies them all: on a
            // phone running a model as large as its memory, that second copy (275 MB for a 27B)
            // pushed half the weights out and took writing from 5 tokens a second to under 1.
            // Read from the file each time, the arrays have one owner and are added to in place.
            var opening = await savedOpening(container: container, like: fresh, key: key)
            // Tools declared part-way through a chat change the prompt from its start. An opening
            // for them is used if there is one, but only the start of a chat is worth making one for.
            if opening == nil, history.isEmpty,
                let made = try? await makeSession(container: container, key: key, request: request, history: []),
                (try? await made.readSharedOpening()) != nil
            {
                await saveOpening(made, key: key)
                opening = made
            }
            if let made = opening {
                opening = nil
                let forked = await made.fork(history: history)
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
            sessionTemplateTools = Set(request.tools.map(\.name))
            sessionLaterTools = [:]
            newMessages = Array(transcript[pendingStart...])
        }
        guard !newMessages.isEmpty else {
            throw ProviderError("The last message in the conversation is already answered.")
        }

        // Until the turn completes the session's state is unknown; a cancelled
        // or failed turn must not be extended.
        sessionMessageIDs = []

        let outcome: Outcome
        do {
            outcome = try await relay(activeSession, messages: newMessages, continuation: continuation)
        } catch {
            session = nil
            sessionKey = nil
            throw error
        }
        let sawToolCall = outcome.sawToolCall
        let sawRejection = outcome.sawRejection
        let stats = outcome.stats
        let stop = outcome.stop

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

    private struct Outcome {
        var sawToolCall = false
        var sawRejection = false
        var stats: GenerationStats?
        var stop = StopReason.stop
    }

    /// Feeds a session its new messages and passes what it writes to the caller as it comes.
    private func relay(
        _ activeSession: ChatSession, messages newMessages: [HarnessKit.Message],
        continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation
    ) async throws -> Outcome {
        var outcome = Outcome()
        let started = Date()
        var firstToken: Date?
        // When each piece of the reply came, to tell a reply that slows as it goes from one that is slow throughout.
        var pieces: [Date] = []
        let readBefore = SystemMemory.now().pageIns
        Self.promptRead.withLock { $0 = (0, 0) }
        // A reply that is given up on leaves no line of its own, and the slow ones are the ones given
        // up on. So the wait for the first piece is noted as it goes, and so is a reply that stops early.
        let waiting = Task.detached {
            var seconds = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { break }
                seconds += 10
                MLXEngine.note("waited \(seconds)s for the first piece", readBack: SystemMemory.now().pageIns - readBefore)
            }
        }
        var finished = false
        defer {
            Self.promptRead.withLock { $0 = (0, 0) }
            waiting.cancel()
            if !finished {
                MLXEngine.note(
                    String(
                        format: "stopped after %.1fs, %d pieces, first piece %@", Date().timeIntervalSince(started), pieces.count,
                        firstToken.map { String(format: "after %.1fs", $0.timeIntervalSince(started)) } ?? "never"),
                    readBack: SystemMemory.now().pageIns - readBefore)
            }
        }

        _ = MLXFailure.install
        _ = MLXFailure.take()
        let stream = activeSession.streamDetails(to: try newMessages.map(Self.chatMessage))
        for try await event in stream {
            try Task.checkCancellation()
            // After an MLX error the stream carries on with nonsense; stop at the first sign.
            if let failure = MLXFailure.take() { throw ModelStoppedError(failure) }
            switch event {
            case .chunk(let text):
                if firstToken == nil {
                    firstToken = Date()
                    waiting.cancel()
                }
                pieces.append(Date())
                continuation.yield(.text(text))
            case .reasoning(let text):
                if firstToken == nil {
                    firstToken = Date()
                    waiting.cancel()
                }
                pieces.append(Date())
                continuation.yield(.reasoning(text))
            case .toolCall(let call):
                outcome.sawToolCall = true
                continuation.yield(.toolCall(Self.toolCall(call)))
            case .rejectedToolCall(let rejection):
                // The library drops calls it cannot use. Hand them to the agent
                // instead, so the model gets an error it can react to.
                outcome.sawToolCall = true
                outcome.sawRejection = true
                if ProcessInfo.processInfo.environment["HARNESS_DEBUG_REJECTED"] != nil {
                    // Development aid: show what the model wrote. Never on by default, since it can hold user data.
                    FileHandle.standardError.write(
                        "REJECTED \(rejection.reason.rawValue) [\(rejection.format)]: \(rejection.rawTextPreview)\n".data(using: .utf8)!)
                }
                continuation.yield(.toolCall(Self.recover(rejection)))
            case .info(let info):
                finished = true
                let wait = firstToken.map { $0.timeIntervalSince(started) } ?? -1
                outcome.stats = GenerationStats(
                    promptTokens: info.promptTokenCount, outputTokens: info.generationTokenCount,
                    tokensPerSecond: info.tokensPerSecond, timeToFirstToken: firstToken.map { $0.timeIntervalSince(started) })
                let cache = try? await activeSession.cacheStatus()
                // Pieces a second over the first and the last fifty pieces, when there are enough to tell them apart.
                func rate(_ times: ArraySlice<Date>) -> Double {
                    guard let first = times.first, let last = times.last, times.count > 1, last > first else { return 0 }
                    return Double(times.count - 1) / last.timeIntervalSince(first)
                }
                let span = min(50, pieces.count / 2)
                MLXEngine.noteMemory(
                    tokensPerSecond: info.tokensPerSecond, promptTokens: info.promptTokenCount, promptTime: info.promptTime,
                    outputTokens: info.generationTokenCount, firstToken: wait, cacheBytes: cache?.memoryBytes ?? 0,
                    early: rate(pieces.prefix(span)), late: rate(pieces.suffix(span)),
                    readBack: SystemMemory.now().pageIns - readBefore)
                if ProcessInfo.processInfo.environment["HARNESS_SHARE_SCALES"] == "check", HadamardQuantizedLinear.differenceCount > 0 {
                    FileHandle.standardError.write(
                        String(
                            format: "SHARED SCALES against biases: %d layer calls, largest difference %.5f of the largest value (%.5f with plain steps), mean %.6f\n",
                            HadamardQuantizedLinear.differenceCount, HadamardQuantizedLinear.largestDifference,
                            HadamardQuantizedLinear.largestPlainDifference,
                            HadamardQuantizedLinear.differenceSum / Double(HadamardQuantizedLinear.differenceCount)
                        ).data(using: .utf8)!)
                }
                if ProcessInfo.processInfo.environment["HARNESS_DEBUG_SESSION"] != nil {
                    let held = MLXEngine.memoryInUse
                    let weights = WeightMapping.held
                    FileHandle.standardError.write(
                        String(
                            format: "STEP read %d tokens in %.2fs, first token after %.2fs, wrote %d at %.1f tok/s, cache %d MB (%d layers compressed, %d waiting, %d left as they are), MLX %d MB now, %d MB at most, weights %d MB in memory (%@: copies %d MB)\n",
                            info.promptTokenCount, info.promptTime, wait, info.generationTokenCount, info.tokensPerSecond,
                            (cache?.memoryBytes ?? 0) >> 20, cache?.compressedLayerCount ?? 0, cache?.pendingLayerCount ?? 0,
                            cache?.skippedLayerCount ?? 0, held.active >> 20, held.peak >> 20, weights.inMemory >> 20,
                            weights.readsFilePages ? "shared" : "private", weights.copied >> 20
                        ).data(using: .utf8)!)
                }
                switch info.stopReason {
                case .length: outcome.stop = .length
                case .cancelled: outcome.stop = .cancelled
                default: outcome.stop = .stop
                }
            case .steering:
                break
            }
        }
        if let failure = MLXFailure.take() { throw ModelStoppedError(failure) }
        return outcome
    }

    /// Answers a request that nothing will follow, such as the one that names a chat, in a session
    /// of its own that is then let go.
    ///
    /// It used to take the place of the chat's session. The chat's next message then found no
    /// session of its own, started again from the saved opening and read the whole conversation
    /// so far: after every reply, since the app asks about memory after each. For a 27B at 43
    /// tokens a second that is a wait that grows with the chat, and the reload pushes part of the
    /// model out of memory just before it is needed.
    private func answerAlone(
        _ request: GenerationRequest, instructions: String, transcript: [HarnessKit.Message], contextTokens: Int,
        continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation
    ) async throws {
        guard let container else { throw ProviderError("No model is loaded.") }
        let key = SessionKey(
            instructions: instructions,
            tools: JSONValue.array(request.tools.map(\.functionDeclaration)).jsonString,
            callable: JSONValue.array((request.callableTools ?? []).map(\.functionDeclaration)).jsonString,
            thinking: request.options.thinking, maxOutputTokens: request.options.maxOutputTokens,
            temperature: request.options.temperature, topP: request.options.topP,
            repetitionPenalty: request.options.repetitionPenalty, contextTokens: contextTokens, tuning: Self.tuningName)
        let pendingStart = (transcript.lastIndex { $0.role == .assistant }).map { $0 + 1 } ?? 0
        let alone = try await makeSession(
            container: container, key: key, request: request, history: try transcript[..<pendingStart].map(Self.chatMessage))
        let outcome = try await relay(alone, messages: Array(transcript[pendingStart...]), continuation: continuation)
        continuation.yield(.finished(outcome.sawToolCall ? .toolCalls : outcome.stop, outcome.stats))
    }

    // MARK: The opening of a chat, kept between chats and between runs

    /// Openings kept beside a model: one for each set of instructions and tools, the newest few.
    static let savedOpenings = 3
    private static func savedOpeningName(_ key: SessionKey) -> String { "prompt-cache-\(fingerprint(key)).safetensors" }

    /// A mark of everything the opening's tokens depend on, to tell whether a saved one still fits.
    private static func fingerprint(_ key: SessionKey) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(key.instructions)|\(key.tools)|\(key.thinking)|\(key.contextTokens)|\(key.tuning)".utf8 {
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
        let alone = request.options.standsAlone == true
        if !alone { adoptPendingAssistant(from: transcript.map(Mark.init), roles: transcript.map(\.role)) }
        // The model is at work for as long as this request runs, whoever asked.
        Self.workBegan()
        defer { Self.workEnded() }
        do {
            try await generate(request, contextTokens: contextTokens, continuation: continuation)
            continuation.finish()
        } catch is CancellationError {
            if !alone {
                session = nil
                sessionKey = nil
            }
            continuation.finish(throwing: CancellationError())
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func makeSession(
        container: ModelContainer, key: SessionKey, request: GenerationRequest, history: [Chat.Message]
    ) async throws -> ChatSession {
        var parameters: GenerateParameters
        if let strategy = Self.cacheCompression {
            // A compressed cache cannot also be a bounded one. The agent keeps the transcript
            // within the context it was given, so the bound is only a second guard.
            parameters = GenerateParameters(
                maxTokens: request.options.maxOutputTokens,
                kvCache: KVCacheConfiguration(strategy: strategy, compatibility: .allowPartial),
                temperature: Float(request.options.temperature), topP: Float(request.options.topP))
        } else {
            parameters = GenerateParameters(
                maxTokens: request.options.maxOutputTokens, maxKVSize: key.contextTokens,
                temperature: Float(request.options.temperature), topP: Float(request.options.topP))
        }
        parameters.repetitionPenalty = request.options.repetitionPenalty.map(Float.init)
        // A prompt is read some hundreds of tokens at a pass, and what a pass works with grows with
        // its length: 947 tokens read 512 at a time took a 9B's memory 987 MB over where it settles,
        // 128 at a time 379 MB, in the same time. A model that fills the device's memory has no such
        // room: on a 12 GB phone a 27B reading a tool's result went 1.25 GB over, and the system
        // made the room by taking it from everything else.
        if let step = Self.prefillStep ?? (loadedFillsMemory ? Self.tightPrefillStep : nil) { parameters.prefill.stepSize = step }
        // A prompt read in several passes says how far it has got after each, for whoever shows the wait.
        parameters.prefill.progress = { read, total in
            MLXEngine.promptRead.withLock { $0 = (read, total) }
            if ProcessInfo.processInfo.environment["HARNESS_DEBUG_SESSION"] != nil {
                FileHandle.standardError.write("PROMPT read \(read) of \(total)\n".data(using: .utf8)!)
            }
        }

        // Thinking on or off, expressed the way this model's chat template expects.
        let reasoning = await container.configuration.reasoningConfig
        var context: [String: any Sendable]?
        if let reasoning {
            context = try? reasoning.promptStrategy.additionalContext(
                forThinkingEnabled: request.options.thinking != .off)
        }

        let components = await components(container: container, request: request)

        let tools: [MLXLMCommon.ToolSpec]? = request.tools.isEmpty ? nil : request.tools.map(Self.toolSpec)
        return ChatSession(
            container, instructions: key.instructions.isEmpty ? nil : key.instructions, history: history,
            generateParameters: parameters, components: components,
            processing: .init(resize: CGSize(width: 768, height: 768)), additionalContext: context,
            tools: tools)
    }

    /// What shapes each reply as it is written: the grammar that holds tool calls to valid syntax,
    /// the cap on thinking, and the gate that holds generation while the app is off screen.
    private func components(container: ModelContainer, request: GenerationRequest) async -> GenerationComponents {
        let reasoning = await container.configuration.reasoningConfig
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
        return components
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

// MARK: Experiment: weights mapped from a file

extension MLXEngine {
    /// EXPERIMENT. When on, the next model loaded uses its weights straight from a mapped file. See `WeightMapping`.
    public nonisolated static func setMapsWeights(_ on: Bool) { WeightMapping.isOn = on }
    public nonisolated static var mapsWeights: Bool { WeightMapping.isOn }

    /// EXPERIMENT. Caps the freed memory MLX keeps for reuse. That memory counts against the app
    /// like any it wrote to, and by default MLX keeps as much as it likes.
    public nonisolated static func setCacheLimit(megabytes: Int) { MLX.Memory.cacheLimit = megabytes << 20 }

    /// Adds a line to `memory-log.txt` after each reply while weights are mapped: how fast it went,
    /// what the app is charged, what the system will still give it, what MLX holds, how much of the
    /// mapped model is in memory, and what the whole phone's memory is doing. Also how fast the
    /// reply was at its start and at its end, how hot the device is (0 to 3), and how much was read
    /// back from storage while it was written. Numbers only, nothing of the chat.
    nonisolated static func noteMemory(
        tokensPerSecond: Double, promptTokens: Int, promptTime: Double, outputTokens: Int, firstToken: Double, cacheBytes: Int,
        early: Double, late: Double, readBack: Int
    ) {
        note(
            String(
                format: "%.1f tok/s (%.1f at the start, %.1f at the end)  wrote %d  prompt %d in %.1fs  first token %.1fs",
                tokensPerSecond, early, late, outputTokens, promptTokens, promptTime, firstToken),
            cacheBytes: cacheBytes, readBack: readBack)
    }

    /// Adds one line to `memory-log.txt` while weights are mapped: the time, what happened, and the
    /// state of memory then. Lines are written when a model has loaded, every ten seconds a reply
    /// keeps the user waiting for its first piece, when a reply ends, and when one is stopped early.
    nonisolated static func note(_ what: String, cacheBytes: Int? = nil, readBack: Int? = nil) {
        guard WeightMapping.isOn else { return }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        func megabytes(_ bytes: Int) -> String { "\(bytes >> 20) MB" }
        let held = memoryInUse
        let weights = WeightMapping.held
        #if os(iOS)
            let available = megabytes(os_proc_available_memory())
        #else
            let available = "n/a"
        #endif
        let system = SystemMemory.now()
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(what)  heat \(ProcessInfo.processInfo.thermalState.rawValue)  "
            + "charged \(megabytes(Int(info.phys_footprint)))  available \(available)  "
            + (cacheBytes.map { "cache \(megabytes($0))  " } ?? "")
            + "MLX in use \(megabytes(held.active)) kept \(megabytes(held.cache)) peak \(megabytes(held.peak))  "
            + "weights in memory \(megabytes(weights.inMemory)) of \(megabytes(weights.mapped)) "
            + "(\(weights.readsFilePages ? "shared" : "private"), \(WeightMapping.holds ? "pinned \(megabytes(weights.pinned))" : "not pinned"): "
            + "copies \(megabytes(weights.copied)), squeezed \(megabytes(weights.compressed)))  "
            + "phone: free \(megabytes(system.free)) apps \(megabytes(system.written)) files \(megabytes(system.files)) "
            + "wired \(megabytes(system.wired)) squeezed \(megabytes(system.compressed))"
            + (readBack.map { "  read back \(megabytes($0)) during the reply" } ?? "") + "\n"
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Harness/memory-log.txt")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// How much of a mapped model is in memory, in bytes, and nil when no weights are mapped. A
    /// model's first reply waits on this: its weights are read from storage as they are first used.
    public nonisolated static var mappedWeights: (inMemory: Int, mapped: Int)? {
        guard WeightMapping.isOn else { return nil }
        let held = WeightMapping.held
        return held.mapped > 0 ? (held.inMemory, held.mapped) : nil
    }

    /// How far the prompt being read has got, in tokens, while it is read in more than one pass.
    fileprivate static let promptRead = OSAllocatedUnfairLock(initialState: (read: 0, total: 0))

    /// How much of a long prompt has been read so far, and nil when none is being read or it is read
    /// in one pass. A tool's result of a thousand tokens takes a 27B on a phone twenty seconds to read.
    public nonisolated static var promptProgress: (read: Int, total: Int)? {
        let now = promptRead.withLock { $0 }
        return now.total > 0 && now.read < now.total ? now : nil
    }

    /// EXPERIMENT. Maps the next model's weights shared, so the GPU reads the file's own pages. See `WeightMapping`.
    public nonisolated static func setSharesWeightPages(_ on: Bool) { WeightMapping.sharesPages = on }

    /// EXPERIMENT. Pins what a mapped model has read for as long as it is at work. See `WeightMapping.hold()`.
    public nonisolated static func setHoldsWeights(_ on: Bool) { WeightMapping.holds = on }

    /// How many are at work with the model: requests being answered, and turns that span several of
    /// them. And when the last of them ended, to say how long the model then sat idle.
    private static let atWork = OSAllocatedUnfairLock(initialState: (count: 0, idleSince: Date?.none))

    /// Says the model is about to be at work: a turn has begun, or a request. Its weights are held in
    /// memory from the first of these until the last has ended. A turn says so as well as its
    /// requests, so the weights are not let go while a tool runs between two of them.
    public nonisolated static func workBegan() {
        let idle = atWork.withLock { state -> TimeInterval? in
            state.count += 1
            defer { state.idleSince = nil }
            return state.count == 1 ? state.idleSince.map { Date().timeIntervalSince($0) } : nil
        }
        // What became of the weights while nobody was using them is what decides how the next reply starts.
        if let idle, idle >= 5 { note(String(format: "back to work after %.0fs idle", idle)) }
        WeightMapping.hold()
    }

    public nonisolated static func workEnded() {
        let left = atWork.withLock { state -> Int in
            state.count = max(0, state.count - 1)
            if state.count == 0 { state.idleSince = Date() }
            return state.count
        }
        if left == 0 { WeightMapping.release() }
    }

    /// What MLX holds: in use, kept for reuse, and the most it has held, in bytes.
    public nonisolated static var memoryInUse: (active: Int, cache: Int, peak: Int) {
        let now = MLX.Memory.snapshot()
        return (now.activeMemory, now.cacheMemory, now.peakMemory)
    }
}

// MARK: Settings for a model that fills the phone's memory

extension MLXEngine {
    private struct Tuning {
        var compression: String?
        var prefillStep: Int?
        var lateTools: Bool
    }

    private static let tuning = OSAllocatedUnfairLock<Tuning>(
        initialState: Tuning(
            compression: ProcessInfo.processInfo.environment["HARNESS_KV"],
            prefillStep: ProcessInfo.processInfo.environment["HARNESS_PREFILL_STEP"].flatMap(Int.init),
            lateTools: ProcessInfo.processInfo.environment["HARNESS_LATE_TOOLS"] != "0"))

    /// How the chat's cache is stored. Nil keeps it as the model wrote it, at 16 bits a number.
    static var cacheCompression: KVCacheConfiguration.Strategy? { compression(named: tuning.withLock { $0.compression }) }
    /// Most tokens of a prompt read in one pass. Nil leaves it to the model (512).
    static var prefillStep: Int? { tuning.withLock { $0.prefillStep } }
    /// Whether tools added part-way through a chat are declared where the conversation stands
    /// and not at the start of the prompt, so that nothing already read is read again.
    static var declaresToolsLate: Bool { tuning.withLock { $0.lateTools } }
    /// The settings as one word, for telling sessions and saved openings made under them apart.
    static var tuningName: String { tuning.withLock { "\($0.compression ?? "plain")/\($0.prefillStep ?? 0)" } }

    /// Sets how the next session stores its cache: "affine8", "turbo0v4", "turbo8v3", "turbo8v2", or nil for as written.
    public nonisolated static func setCacheCompression(_ name: String?) {
        tuning.withLock { $0.compression = compression(named: name) == nil ? nil : name }
    }

    public nonisolated static func setPrefillStep(_ tokens: Int?) { tuning.withLock { $0.prefillStep = tokens } }

    /// Tokens of a prompt read in one pass by a model that fills the device's memory, unless a step is set.
    static let tightPrefillStep = 128

    public nonisolated static func setDeclaresToolsLate(_ on: Bool) { tuning.withLock { $0.lateTools = on } }

    /// The words that declare tools in a message, in the form a template declares them at the start.
    static func declarations(_ tools: [HarnessKit.ToolSpec]) -> String {
        "\n\nYou can now also call these functions, in the same way as the others:\n<tools>\n"
            + tools.map { $0.functionDeclaration.jsonString }.joined(separator: "\n") + "\n</tools>"
    }

    private static func compression(named name: String?) -> KVCacheConfiguration.Strategy? {
        switch name {
        case "affine8": return .affine(.eightBit)
        case "turbo0v4": return .turboQuant(.qualityFirst)
        case "turbo8v3": return .turboQuant(.balanced)
        case "turbo8v2": return .turboQuant(.memoryFirst)
        default: return nil
        }
    }
}

/// What the whole device's memory holds, in bytes.
struct SystemMemory {
    var free = 0
    /// Memory apps and the system wrote to: it can be squeezed but not dropped.
    var written = 0
    /// Memory holding files, a mapped model among them: dropped first when memory runs short.
    var files = 0
    var wired = 0
    var compressed = 0
    /// Bytes read back from storage since the device started.
    var pageIns = 0

    static func now() -> SystemMemory {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return SystemMemory() }
        let page = Int(vm_kernel_page_size)
        return SystemMemory(
            free: Int(stats.free_count) * page, written: Int(stats.internal_page_count) * page,
            files: Int(stats.external_page_count) * page, wired: Int(stats.wire_count) * page,
            compressed: Int(stats.compressor_page_count) * page, pageIns: Int(stats.pageins) * page)
    }
}
