import Foundation
import UIKit
import HarnessKit
import HarnessMLX
import Observation

/// App-wide state: chats, presets, the model library and downloads.
@MainActor
@Observable
final class AppModel {
    enum LoadState: Equatable {
        case idle
        case loading(name: String, fraction: Double)
    }

    struct DownloadState: Equatable {
        var fraction: Double
        var error: String?
    }

    /// What a chat needs to run a turn.
    struct ResolvedModel {
        var provider: any ModelProvider
        var contextTokens: Int
        var capabilities: ModelCapabilities
        var sampling = SamplingSettings.standard
    }

    let store = Store()
    let memory: MemoryStore
    let connectors: ConnectorsModel
    let device = DeviceProfile.current()

    var conversations: [Conversation]
    var presets: [HarnessPreset]
    var skills: [Skill]
    /// Whether saved memory is used at all. Off: nothing is recalled and nothing new is saved.
    var memoryEnabled: Bool = UserDefaults.standard.object(forKey: "memoryEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(memoryEnabled, forKey: "memoryEnabled") }
    }
    /// What goes into the prompt as memory.
    var memoryText: String { memoryEnabled ? memory.text : "" }
    var library: Library
    var downloads: [String: DownloadState] = [:]
    var loadState = LoadState.idle

    private var chatModels: [UUID: ChatModel] = [:]
    /// Downloads in flight. Saved so they can finish after the app is closed and reopened.
    private var pending: [PendingInstall]
    private let downloader = BackgroundDownloader.shared

    /// The one app model, shared with Shortcuts actions, which run outside any view.
    static let shared = AppModel()

    /// A chat that something outside the chat screen wants shown, such as a Shortcuts action.
    var openConversation: UUID?

    init() {
        memory = MemoryStore(url: store.memoryURL)
        connectors = ConnectorsModel(store: store)
        conversations = store.loadConversations()
        library = store.loadLibrary()
        pending = store.loadPendingInstalls()

        // Built-in presets always exist; saved copies keep the user's edits.
        var loaded = (store.loadPresets() ?? []).map(\.withCurrentInstructions)
        for builtIn in HarnessPreset.builtIns.reversed() where !loaded.contains(where: { $0.id == builtIn.id }) {
            loaded.insert(builtIn, at: 0)
        }
        // Built-in skills always exist; saved copies keep the user's edits and on/off choice.
        var savedSkills = store.loadSkills() ?? []
        if store.loadSkills() == nil {
            // First launch with skills: switch them on in built-in presets the user had already edited.
            for index in loaded.indices {
                guard let original = HarnessPreset.builtIns.first(where: { $0.id == loaded[index].id }),
                    original.tools.contains(.skills), !loaded[index].tools.contains(.skills)
                else { continue }
                loaded[index].tools.append(.skills)
            }
            store.save(loaded)
            store.save(Skill.builtIns)
        }
        for builtIn in Skill.builtIns.reversed() where !savedSkills.contains(where: { $0.id == builtIn.id }) {
            savedSkills.insert(builtIn, at: 0)
        }
        savedSkills = savedSkills.map(\.withCurrentInstructions)
        presets = loaded
        skills = savedSkills

        if library.selected == nil || !isAvailable(library.selected) {
            library.selected = firstAvailableModel()
        }
        resumeDownloads()
    }

    /// True while any chat is generating. Used to keep the screen awake.
    var isGenerating: Bool { chatModels.values.contains { $0.isRunning } }

    /// Stops the work chats do with the model after a reply, in every chat, and waits for the model to be free.
    func stopHousekeeping() async {
        for chat in chatModels.values { await chat.stopHousekeeping() }
    }

    /// Called when the app leaves the foreground.
    ///
    /// A model this app runs is held still where it is. iOS slows its
    /// graphics-processor work to a sixth once the app is off screen and
    /// refuses it within about a minute, and a reply cut off that way has to be
    /// started again. Held between two tokens, it carries on from the same word
    /// when the app comes back.
    ///
    /// Apple's model and servers work outside this app, so their turns carry
    /// on, with time asked of iOS to finish.
    func didEnterBackground() {
        downloader.setActive(false)
        let running = chatModels.values.filter(\.isRunning)
        guard !running.isEmpty else { return }
        if case .local = library.selected {
            GenerationGate.close()
            return
        }
        let application = UIApplication.shared
        var permit = UIBackgroundTaskIdentifier.invalid
        permit = application.beginBackgroundTask(withName: "Finish the reply") {
            application.endBackgroundTask(permit)
            permit = .invalid
        }
        Task {
            for chat in running { await chat.waitForTurn() }
            if permit != .invalid {
                application.endBackgroundTask(permit)
                permit = .invalid
            }
        }
    }

    /// Called when the app comes back to the foreground: carries on with turns that were paused.
    func didBecomeActive() {
        GenerationGate.open()
        downloader.setActive(true)
        for chat in chatModels.values { chat.resumeIfPaused() }
    }

    // MARK: Presets

    func preset(_ id: UUID) -> HarnessPreset {
        presets.first { $0.id == id } ?? presets.first { $0.id == library.defaultPresetID } ?? .assistant
    }

    func save(_ preset: HarnessPreset) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        store.save(presets)
    }

    func delete(_ preset: HarnessPreset) {
        guard !preset.isBuiltIn else { return }
        presets.removeAll { $0.id == preset.id }
        if library.defaultPresetID == preset.id { library.defaultPresetID = HarnessPreset.assistantID }
        store.save(presets)
        store.save(library)
    }

    /// Restores a built-in preset to how it shipped.
    func reset(_ preset: HarnessPreset) {
        guard let original = HarnessPreset.builtIns.first(where: { $0.id == preset.id }) else { return }
        save(original)
    }

    // MARK: Skills

    /// A skill the model has drafted, waiting for the user to keep or discard it.
    struct SkillProposal: Identifiable {
        let id = UUID()
        var skill: Skill
        fileprivate let decide: (Skill?) -> Void
    }

    /// The proposal on screen, if any.
    var skillProposal: SkillProposal?

    /// Shows a drafted skill to the user and waits for their choice. Returns the
    /// skill as saved, or nil if they declined or the turn was stopped.
    func propose(_ skill: Skill) async -> Skill? {
        // One at a time: a second draft while one is on screen is declined.
        guard skillProposal == nil else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Skill?, Never>) in
                var answered = false
                skillProposal = SkillProposal(skill: skill) { choice in
                    guard !answered else { return }
                    answered = true
                    continuation.resume(returning: choice)
                }
            }
        } onCancel: {
            Task { @MainActor in self.answerProposal(nil) }
        }
    }

    /// Keeps the proposed skill as edited, or discards it with nil.
    func answerProposal(_ skill: Skill?) {
        guard let proposal = skillProposal else { return }
        skillProposal = nil
        var saved = skill
        if var skill {
            // A name already in use by another skill gets a number, so nothing is overwritten.
            let base = skill.name
            var suffix = 2
            while skills.contains(where: { $0.name == skill.name && $0.id != skill.id }) {
                skill.name = "\(base)-\(suffix)"
                suffix += 1
            }
            save(skill)
            saved = skill
        }
        proposal.decide(saved)
    }

    func save(_ skill: Skill) {
        if let index = skills.firstIndex(where: { $0.id == skill.id }) {
            skills[index] = skill
        } else {
            skills.append(skill)
        }
        store.save(skills)
    }

    func delete(_ skill: Skill) {
        skills.removeAll { $0.id == skill.id }
        store.save(skills)
    }

    /// How much of the loaded model is in memory, in bytes, when its weights are used from a mapped
    /// file, and nil otherwise. Asks the system about every page of the file, so not for the main thread.
    nonisolated static func weightsInMemory() -> (inMemory: Int, mapped: Int)? { MLXEngine.mappedWeights }

    /// EXPERIMENT. Maps the next model's weights shared, for measuring that against the usual way.
    nonisolated static func setSharesWeightPages(_ on: Bool) { MLXEngine.setSharesWeightPages(on) }

    // MARK: Chats

    func chatModel(for id: UUID) -> ChatModel? {
        if let existing = chatModels[id] { return existing }
        guard let conversation = conversations.first(where: { $0.id == id }) else { return nil }
        let model = ChatModel(conversation: conversation, app: self)
        chatModels[id] = model
        return model
    }

    /// Returns an empty chat to start in, reusing one if it exists.
    func newConversation() -> UUID {
        if let empty = conversations.first(where: { $0.isEmpty }) {
            return empty.id
        }
        let conversation = Conversation(presetID: library.defaultPresetID)
        conversations.insert(conversation, at: 0)
        return conversation.id
    }

    func update(_ conversation: Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
        conversations.sort { $0.updatedAt > $1.updatedAt }
        if !conversation.isEmpty { store.save(conversation) }
    }

    func delete(_ conversation: Conversation) {
        chatModels[conversation.id]?.stop()
        chatModels[conversation.id] = nil
        conversations.removeAll { $0.id == conversation.id }
        store.delete(conversation)
    }

    // MARK: Models

    var isSimulator: Bool {
        #if targetEnvironment(simulator)
            return true
        #else
            return false
        #endif
    }

    func name(of ref: ModelRef?) -> String {
        switch ref {
        case .local(let repo): return library.installed.first { $0.repo == repo }?.name ?? "Model"
        case .remote(let id): return library.endpoints.first { $0.id == id }?.name ?? "Server"
        case .apple: return "Apple Intelligence"
        case .demo: return "Demo Model"
        case nil: return "No Model"
        }
    }

    func isAvailable(_ ref: ModelRef?) -> Bool {
        switch ref {
        case .local(let repo): return library.installed.contains { $0.repo == repo }
        case .remote(let id): return library.endpoints.contains { $0.id == id }
        case .apple: return appleModelIssue == nil
        case .demo: return isSimulator
        case nil: return false
        }
    }

    /// How much text the selected model takes at once, in tokens.
    var selectedContextTokens: Int {
        switch library.selected {
        case .local(let repo): return library.installed.first { $0.repo == repo }?.contextTokens ?? 16384
        case .apple: return (try? appleModel().contextTokens) ?? 8192
        case .remote: return 16384
        case .demo, nil: return 8192
        }
    }

    /// Whether this version of iOS has the system model at all.
    var hasAppleModel: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// Why the system model cannot be used right now, or nil when it can.
    var appleModelIssue: String? {
        guard #available(iOS 26.0, *) else { return "Apple Intelligence needs iOS 26 or later." }
        return AppleModelProvider.unavailableReason
    }

    /// The system model, ready to use. The availability check is kept out of the async code that calls this.
    private func appleModel() throws -> ResolvedModel {
        guard #available(iOS 26.0, *) else { throw ProviderError("Apple Intelligence needs iOS 26 or later.") }
        if let issue = AppleModelProvider.unavailableReason { throw ProviderError(issue) }
        return ResolvedModel(
            provider: AppleModelProvider(), contextTokens: AppleModelProvider.contextTokens,
            capabilities: .init(vision: false, tools: true, thinking: false))
    }

    private func firstAvailableModel() -> ModelRef? {
        if !isSimulator, let model = library.installed.first { return .local(model.repo) }
        if let endpoint = library.endpoints.first { return .remote(endpoint.id) }
        // Nothing installed: the system's own model works straight away where there is one.
        if appleModelIssue == nil { return .apple }
        if let model = library.installed.first { return .local(model.repo) }
        return isSimulator ? .demo : nil
    }

    func select(_ ref: ModelRef) {
        library.selected = ref
        store.save(library)
    }

    func capabilities(of ref: ModelRef?) -> ModelCapabilities {
        switch ref {
        case .apple:
            return .init(vision: false, tools: true, thinking: false)
        case .local(let repo):
            return library.installed.first { $0.repo == repo }?.capabilities ?? .init()
        case .remote:
            // A server's abilities are not known ahead of time; let the user try.
            return .init(vision: true, tools: true, thinking: true)
        case .demo:
            return .init(vision: false, tools: true, thinking: true)
        case nil:
            return .init()
        }
    }

    /// Makes the selected model ready to generate, loading it into memory if needed.
    func resolveSelectedModel() async throws -> ResolvedModel {
        try await resolveModel(library.selected)
    }

    /// Makes a model ready to generate, loading it into memory if needed.
    func resolveModel(_ ref: ModelRef?) async throws -> ResolvedModel {
        guard let ref, isAvailable(ref) else {
            throw ProviderError("Choose a model to start chatting.")
        }
        switch ref {
        case .apple:
            // The system runs its model in its own memory; ours can be given back.
            await MLXEngine.shared.unload()
            return try appleModel()
        case .demo:
            return ResolvedModel(provider: DemoProvider.make(), contextTokens: 8192, capabilities: capabilities(of: ref))
        case .remote(let id):
            guard let endpoint = library.endpoints.first(where: { $0.id == id }) else {
                throw ProviderError("That server is no longer set up.")
            }
            await MLXEngine.shared.unload()
            return ResolvedModel(
                provider: OpenAICompatibleProvider(endpoint: endpoint), contextTokens: 16384,
                capabilities: capabilities(of: ref))
        case .local(let repo):
            guard let model = library.installed.first(where: { $0.repo == repo }) else {
                throw ProviderError("That model is no longer installed.")
            }
            if isSimulator {
                throw ProviderError("On-device models need a real iPhone or iPad. In the simulator, use the demo model or a server.")
            }
            let directory = store.modelDirectory(for: repo)
            if await MLXEngine.shared.loadedModelDirectory != directory {
                loadState = .loading(name: model.name, fraction: 0)
                defer { loadState = .idle }
                // EXPERIMENT: weights used straight from a mapped file, when switched on in Settings.
                MLXEngine.setMapsWeights(UserDefaults.standard.bool(forKey: "mapWeights"))
                // With weights mapped, the memory MLX keeps for reuse is what crowds them out of
                // memory: capped at 64 MB, Bonsai 9B on a Mac peaked at 419 MB charged, not 1.1 GB, at the same speed.
                if UserDefaults.standard.bool(forKey: "mapWeights") { MLXEngine.setCacheLimit(megabytes: 64) }
                try await MLXEngine.shared.load(directory: directory) { fraction in
                    Task { @MainActor in
                        if case .loading = self.loadState {
                            self.loadState = .loading(name: model.name, fraction: fraction)
                        }
                    }
                }
            }
            return ResolvedModel(
                provider: MLXEngine.shared.provider(contextTokens: model.contextTokens),
                contextTokens: model.contextTokens, capabilities: model.capabilities, sampling: sampling(for: model))
        }
    }

    /// The settings a model's maker recommends, read from the model's own files.
    /// Offered in the model's settings; the app starts every model at its own standard values.
    func makerSampling(for model: InstalledModel) -> SamplingSettings {
        let file = store.modelDirectory(for: model.repo).appendingPathComponent("generation_config.json")
        let config = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        return SamplingSettings(generationConfig: config)
    }

    /// The settings a model runs with: the user's, or else the app's standard ones.
    func sampling(for model: InstalledModel) -> SamplingSettings {
        model.sampling ?? .standard
    }

    /// Saves the user's settings for a model. Nil goes back to the standard ones.
    func setSampling(_ sampling: SamplingSettings?, for repo: String) {
        guard let index = library.installed.firstIndex(where: { $0.repo == repo }) else { return }
        library.installed[index].sampling = sampling
        store.save(library)
    }

    /// Builds the tool set a preset asks for: the tools declared from the start,
    /// and the connectors held back until a request needs them. The built-in
    /// tools (web, code, memory, skills) have a switch each and are on in a new
    /// preset. Every connector, on this device or added, is second class: one
    /// line in the prompt, opened on demand.
    func toolSet(for preset: HarnessPreset) -> (tools: [any Tool], groups: [ToolGroup]) {
        let builtIn = preset.tools.flatMap { tool -> [any Tool] in
            switch tool {
            case .skills:
                let enabled = skills.filter(\.isEnabled)
                let propose = SaveSkillTool(existing: skills) { [weak self] skill in await self?.propose(skill) }
                guard !enabled.isEmpty else { return [propose] }
                let update = UpdateSkillTool(skills: enabled) { [weak self] skill in await self?.propose(skill) }
                return [UseSkillTool(skills: skills), propose, update]
            case .webSearch: return [WebSearchTool()]
            case .fetchPage: return [FetchPageTool()]
            case .runJavaScript: return [JavaScriptTool()]
            case .saveMemory: return memoryEnabled ? [SaveMemoryTool(store: memory)] : []
            }
        }
        let onDevice = preset.connectors.map { connector in
            ToolGroup(
                name: connector.rawValue, title: connector.title, summary: connector.detail,
                tools: connector.tools(source: EventKitSource.shared))
        }
        let groups = onDevice + connectors.groups(for: preset.servers)
        return (builtIn, preset.tools.contains(.skills) ? ToolGroup.linking(groups, to: skills) : groups)
    }

    // MARK: Connectors

    /// Adds a connector and switches it on in the preset new chats use, so it works straight away.
    func addConnector(
        address: String, name: String = "", clientID: String = "", clientSecret: String = "",
        scopes: [String]? = nil, onlyTools: [String]? = nil, signInFirst: Bool = false, withCode: Bool = false,
        summary: String? = nil
    ) async throws {
        let server = try await connectors.add(
            address: address, name: name, clientID: clientID, clientSecret: clientSecret, scopes: scopes,
            onlyTools: onlyTools, signInFirst: signInFirst, withCode: withCode, summary: summary)
        var target = preset(library.defaultPresetID)
        if !target.servers.contains(server.id) {
            target.servers.append(server.id)
            save(target)
        }
    }

    func removeConnector(_ id: UUID) {
        connectors.remove(id)
        for var preset in presets where preset.servers.contains(id) {
            preset.servers.removeAll { $0 == id }
            save(preset)
        }
    }

    // MARK: Downloads

    func isInstalled(_ repo: String) -> Bool {
        library.installed.contains { $0.repo.caseInsensitiveCompare(repo) == .orderedSame }
    }

    /// Downloads a model that has passed the fit check and adds it to the library.
    /// The download continues if the app is put in the background or closed.
    func install(_ info: HubModelInfo, name: String, report: FitReport) {
        let repo = info.repo
        guard !pending.contains(where: { $0.repo == repo }), !isInstalled(repo) else { return }
        let install = PendingInstall(
            repo: repo, name: name,
            files: ModelDownloader.neededFiles(in: info).map { .init(path: $0.path, size: $0.size) },
            contextTokens: report.contextTokens, capabilities: report.capabilities)
        pending.append(install)
        store.save(pending)
        downloads[repo] = DownloadState(fraction: fraction(of: install, receiving: 0))
        downloader.download(install)
    }

    func cancelDownload(_ repo: String) {
        downloader.cancel(repo: repo)
        pending.removeAll { $0.repo == repo }
        store.save(pending)
        downloads[repo] = nil
    }

    /// Tries a failed download again. Files that already arrived are kept.
    func retryDownload(_ repo: String) {
        guard let install = pending.first(where: { $0.repo == repo }) else { return }
        downloads[repo] = DownloadState(fraction: fraction(of: install, receiving: 0))
        downloader.download(install)
    }

    private func fraction(of install: PendingInstall, receiving: Int64) -> Double {
        let total = install.totalBytes
        guard total > 0 else { return 0 }
        return min(1, Double(downloader.completedBytes(of: install) + receiving) / Double(total))
    }

    /// Reconnects to downloads that were running when the app last closed.
    private func resumeDownloads() {
        downloader.onProgress = { [weak self] repo, receiving in
            guard let self, let install = self.pending.first(where: { $0.repo == repo }) else { return }
            self.downloads[repo] = DownloadState(fraction: self.fraction(of: install, receiving: receiving))
        }
        downloader.onFinished = { [weak self] repo, error in
            self?.downloadEnded(repo, error: error)
        }
        downloader.start(modelsDirectory: store.modelsDirectory)
        // An earlier version kept a second copy of each mapped model's weights. Off the main thread:
        // removing 8 GB takes a moment.
        let models = store.modelsDirectory
        Task.detached(priority: .utility) { ModelDownloader.removeLeftoverCopies(in: models) }

        for install in pending {
            downloads[install.repo] = DownloadState(fraction: fraction(of: install, receiving: 0))
        }
        Task {
            let active = await downloader.activeRepos()
            // Anything with no transfers left either finished while the app was closed or was interrupted.
            for install in pending where !active.contains(install.repo) {
                if downloader.isComplete(install) {
                    downloadEnded(install.repo, error: nil)
                } else {
                    downloader.download(install)
                }
            }
        }
    }

    private func downloadEnded(_ repo: String, error: String?) {
        guard let install = pending.first(where: { $0.repo == repo }) else { return }
        guard downloader.isComplete(install) else {
            downloads[repo] = DownloadState(
                fraction: fraction(of: install, receiving: 0),
                error: error ?? "The download was interrupted. Tap to try again.")
            return
        }
        pending.removeAll { $0.repo == repo }
        store.save(pending)
        downloads[repo] = nil
        guard !isInstalled(repo) else { return }
        library.installed.append(
            InstalledModel(
                repo: repo, name: install.name, sizeBytes: install.totalBytes,
                contextTokens: install.contextTokens, capabilities: install.capabilities))
        if library.selected == nil || library.selected == .demo { library.selected = .local(repo) }
        store.save(library)
    }

    func remove(_ model: InstalledModel) {
        try? FileManager.default.removeItem(at: store.modelDirectory(for: model.repo))
        library.installed.removeAll { $0.repo == model.repo }
        if library.selected == .local(model.repo) { library.selected = firstAvailableModel() }
        store.save(library)
        Task { await MLXEngine.shared.unload() }
    }

    // MARK: Servers

    func save(_ endpoint: RemoteEndpoint) {
        if let index = library.endpoints.firstIndex(where: { $0.id == endpoint.id }) {
            library.endpoints[index] = endpoint
        } else {
            library.endpoints.append(endpoint)
        }
        if library.selected == nil || library.selected == .demo { library.selected = .remote(endpoint.id) }
        store.save(library)
    }

    func remove(_ endpoint: RemoteEndpoint) {
        library.endpoints.removeAll { $0.id == endpoint.id }
        Keychain.set("", for: "endpoint.\(endpoint.id.uuidString)")
        if library.selected == .remote(endpoint.id) { library.selected = firstAvailableModel() }
        store.save(library)
    }
}

/// A canned model for the simulator, so the interface can be used without a device.
enum DemoProvider {
    static func make() -> ScriptedProvider {
        ScriptedProvider(delay: .milliseconds(25)) { request in
            let last = request.messages.last
            let toolNames = Set(request.tools.map(\.name))

            if let last, last.role == .tool {
                return .init(
                    text: "Here is what I found.\n\n**Result:** \(last.text.prefix(200))\n\nThis reply comes from the demo model. Install a model on a real device, or add a server, for real answers.")
            }
            let question = last?.text ?? ""
            // A connector's tools are described as "[Name] …": mentioning the name uses its first tool.
            if let tool = request.tools.first(where: { spec in
                guard spec.description.hasPrefix("["), let end = spec.description.firstIndex(of: "]") else { return false }
                return question.lowercased().contains(spec.description[spec.description.index(after: spec.description.startIndex)..<end].lowercased())
            }) {
                // Every required argument gets the last word of the question; enough to show a real round trip.
                let word = question.split(separator: " ").last.map(String.init) ?? question
                let required = tool.parameters["required"]?.arrayValue?.compactMap(\.stringValue) ?? ["query"]
                return .init(
                    reasoning: "The user mentioned a connector, so I will use it.",
                    toolCalls: [ToolCall(name: tool.name, arguments: .object(Dictionary(uniqueKeysWithValues: required.map { ($0, .string(word)) })))])
            }
            if question.hasPrefix("[Attached photo") {
                return .init(
                    reasoning: "I cannot see the photo, but I was given the text read from it.",
                    text: "I can't see images, but this was read from your photo:\n\n> \(question.components(separatedBy: "\n").dropFirst().prefix(4).joined(separator: " "))")
            }
            if toolNames.contains("read_document"), question.lowercased().hasSuffix("total?") {
                return .init(
                    reasoning: "The total is not in the part I was shown, so I will search the document.",
                    toolCalls: [ToolCall(name: "read_document", arguments: ["search": "total"])])
            }
            if toolNames.contains("use_skill"), question.lowercased().contains("email") {
                return .init(
                    reasoning: "This is an email task, and there is a skill for that.",
                    toolCalls: [ToolCall(name: "use_skill", arguments: ["name": "write-email"])])
            }
            if toolNames.contains("calendar_list"), question.lowercased().contains("calendar") {
                return .init(
                    reasoning: "The user asked about their schedule, so I will look at the calendar.",
                    toolCalls: [ToolCall(name: "calendar_list", arguments: ["day": "tomorrow"])])
            }
            if toolNames.contains("reminders_add"), question.lowercased().contains("remind") {
                return .init(
                    reasoning: "The user wants a reminder.",
                    toolCalls: [ToolCall(name: "reminders_add", arguments: ["title": "Call the plumber", "due": "tomorrow 5pm"])])
            }
            if toolNames.contains("run_javascript"), question.rangeOfCharacter(from: .decimalDigits) != nil {
                return .init(
                    reasoning: "The user asked something numeric. I should compute it rather than guess.",
                    toolCalls: [ToolCall(name: "run_javascript", arguments: ["code": "const values = [12, 30, 58];\nvalues.reduce((a, b) => a + b, 0)"])])
            }
            if toolNames.contains("web_search"), question.lowercased().contains("search") {
                return .init(
                    reasoning: "This needs current information, so I will search.",
                    toolCalls: [ToolCall(name: "web_search", arguments: ["query": .string(String(question.prefix(60)))])])
            }
            return .init(
                reasoning: "A simple question. I can answer directly.",
                text: """
                    This is the **demo model**, a scripted stand-in for the simulator.

                    It shows how a chat looks:

                    - Thinking appears above, collapsed
                    - Tool use shows as a single line you can open
                    - Answers render Markdown, including `code`

                    ```swift
                    let greeting = "Hello from Resident"
                    print(greeting)
                    ```

                    Ask something with a number in it to see a tool run.
                    """)
        }
    }
}
