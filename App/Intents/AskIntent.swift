import AppIntents
import BackgroundTasks
import HarnessKit
import HarnessMLX

/// An agent, as Shortcuts shows it.
struct AgentEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent"
    static let defaultQuery = AgentQuery()

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

/// A model, as Shortcuts shows it.
struct ModelEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Model"
    static let defaultQuery = ModelQuery()

    /// "apple", "local:<repository>" or "remote:<id>".
    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ ref: ModelRef, name: String) {
        switch ref {
        case .apple: id = "apple"
        case .local(let repo): id = "local:" + repo
        case .remote(let server): id = "remote:" + server.uuidString
        case .demo: id = "demo"
        }
        self.name = name
    }

    var ref: ModelRef? {
        if id == "apple" { return .apple }
        if id.hasPrefix("local:") { return .local(String(id.dropFirst(6))) }
        if id.hasPrefix("remote:"), let server = UUID(uuidString: String(id.dropFirst(7))) { return .remote(server) }
        return nil
    }
}

struct ModelQuery: EntityQuery {
    @MainActor
    private func all() -> [ModelEntity] {
        let app = AppModel.shared
        var refs: [ModelRef] = app.appleModelIssue == nil ? [.apple] : []
        refs += app.library.installed.map { .local($0.repo) }
        refs += app.library.endpoints.map { .remote($0.id) }
        return refs.map { ModelEntity($0, name: app.name(of: $0)) }
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [ModelEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ModelEntity] { all() }
}

struct AgentQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [AgentEntity] {
        AppModel.shared.presets.filter { identifiers.contains($0.id) }.map { AgentEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [AgentEntity] {
        AppModel.shared.presets.map { AgentEntity(id: $0.id, name: $0.name) }
    }
}

/// "Ask Resident" in Shortcuts: sends a message to an agent in a new chat and
/// hands back the reply, so it can be chained with other actions.
///
/// It runs without bringing the app to the front, whichever model answers. A
/// model this app runs itself works too: on an iPhone with iOS 27.2, LFM3
/// answered from Shortcuts at its usual 76 to 95 tokens a second with the app
/// not on screen.
///
/// An action normally has 30 seconds. An agent turn with a few tool calls
/// takes longer, so this is a long-running action: iOS lets it carry on while
/// it reports progress, and shows that progress as a Live Activity with a stop
/// button. That needs iOS 27, so the action exists from iOS 27 on.
/// For a model this app runs it also asks to keep the GPU, without which iOS
/// stops the model after about a minute off screen.
@available(iOS 27.0, *)
struct AskIntent: AppIntent, LongRunningIntent, CancellableIntent {
    static let title: LocalizedStringResource = "Ask Resident"
    static let description = IntentDescription(
        "Sends a message to one of your agents and returns its reply. The chat is kept in Resident.")
    static let openAppWhenRun = false

    @Parameter(title: "Message")
    var message: String

    @Parameter(title: "Agent", description: "The agent to ask. Leave empty for the one new chats use.")
    var agent: AgentEntity?

    @Parameter(title: "Model", description: "The model that answers. Leave empty for the one selected in Resident.")
    var model: ModelEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$agent) \(\.$message)") {
            \.$model
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let app = AppModel.shared
        // An action runs with the app off screen: nothing may be left held from when the app was last left.
        GenerationGate.open()
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AskError.emptyMessage }
        let id = app.newConversation()
        guard let chat = app.chatModel(for: id) else { throw AskError.failed("The chat could not be started.") }
        if let agent, app.presets.contains(where: { $0.id == agent.id }) { chat.setPreset(agent.id) }
        if let ref = model?.ref {
            guard app.isAvailable(ref) else { throw AskError.failed("That model is no longer in Resident.") }
            chat.modelOverride = ref
        }
        // Progress is the agent's steps: each reply or tool call it makes is one.
        let limit = 8
        progress.totalUnitCount = Int64(limit)
        let before = chat.conversation.messages.count
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                let steps = chat.conversation.messages.dropFirst(before).filter { $0.role == .assistant }.count
                progress.completedUnitCount = Int64(min(limit - 1, steps))
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer { watcher.cancel() }
        // A model this app runs needs the GPU, which iOS takes from an app off screen
        // after about a minute unless the task asks to keep it. Asking needs the
        // Background GPU Access entitlement and a device that allows it.
        var isLocal = false
        if case .local = chat.modelOverride ?? app.library.selected { isLocal = true }
        let wantsGPU = isLocal && BGTaskScheduler.supportedResources.contains(.gpu)
        let started = Started()
        let run: (LongRunningTaskOptions) async throws -> String? = { options in
            try await performBackgroundTask(
                options: options,
                operation: {
                    started.mark()
                    return await chat.sendAndWait(text)
                },
                onCancel: { _ in Task { @MainActor in chat.stop() } })
        }
        let reply: String?
        do {
            reply = try await run(wantsGPU ? [.requiresGPU] : [])
        } catch where wantsGPU && !started.value {
            // Refused before it began, as a build without the entitlement is: run with what every app gets.
            reply = try await run([])
        }
        progress.completedUnitCount = Int64(limit)
        if reply == nil, chat.pausedForBackground {
            throw AskError.failed(
                "iOS stopped the model before it finished: it took the graphics processor back from Resident, which was not on screen. Open Resident to let it finish, or choose Apple Intelligence for longer tasks.")
        }
        if let error = chat.errorMessage, reply == nil { throw AskError.failed(error) }
        guard let reply else { throw AskError.failed("The agent gave no reply.") }
        return .result(value: Self.plainText(reply))
    }

    /// A reply as plain text: Shortcuts shows Markdown's marks as they are typed.
    static func plainText(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        let inline = (try? AttributedString(markdown: markdown, options: options)).map { String($0.characters) } ?? markdown
        // Headings and fenced-code marks are block syntax, left in by the inline pass.
        return inline.components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { return nil }
            if trimmed.hasPrefix("#") { return trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
            return line
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Whether the action's work has begun, which decides if it is safe to start it a second time.
private final class Started: @unchecked Sendable {
    private let lock = NSLock()
    private var began = false
    var value: Bool { lock.withLock { began } }
    func mark() { lock.withLock { began = true } }
}

enum AskError: Error, CustomLocalizedStringResourceConvertible {
    case emptyMessage
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyMessage: return "There was no message to send."
        case .failed(let reason): return "\(reason)"
        }
    }
}

@available(iOS 27.0, *)
struct HarnessShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskIntent(),
            phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) a question"],
            shortTitle: "Ask Resident", systemImageName: "sparkles")
    }
}
