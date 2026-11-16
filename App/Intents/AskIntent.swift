import AppIntents
import BackgroundTasks
import UIKit
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

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

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
/// model this app runs itself works too, and asks to keep the GPU, without
/// which iOS stops the model after about a minute off screen.
///
/// An action normally has 30 seconds. An agent turn with a few tool calls
/// takes longer, so this is a long-running action: iOS lets it carry on while
/// it reports progress, and shows that progress as a Live Activity with a stop
/// button. That needs iOS 27, so the action exists from iOS 27 on.
///
/// Shortcuts itself stops waiting for any one action after about four minutes,
/// and a model on the device, slowed to a fifth of its speed off screen, can
/// need longer. So an action that is not done in three minutes holds the turn
/// where it is and returns nothing; "Wait for Resident" picks it up from
/// there. A shortcut that may run long follows Ask Resident with that action,
/// repeated a few times.
@available(iOS 27.0, *)
struct AskIntent: AppIntent, LongRunningIntent, CancellableIntent {
    static let title: LocalizedStringResource = "Ask Resident"
    static let description = IntentDescription(
        "Sends a message to one of your agents and returns its reply. The chat is kept in Resident. If the agent needs more than three minutes, this returns empty text and the agent's work is held: add Wait for Resident after it to carry on and get the reply.")
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
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AskError.emptyMessage }
        let id = app.newConversation()
        guard let chat = app.chatModel(for: id) else { throw AskError.failed("The chat could not be started.") }
        if let agent, app.presets.contains(where: { $0.id == agent.id }) { chat.setPreset(agent.id) }
        if let ref = model?.ref {
            guard app.isAvailable(ref) else { throw AskError.failed("That model is no longer in Resident.") }
            chat.modelOverride = ref
        }
        ActionChat.remember(id, model: model?.id)
        let reply = try await ActionRun.run(self, chat: chat) { chat.send(text) }
        return .result(value: reply)
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

/// "Wait for Resident" in Shortcuts: carries on with what the last Ask Resident
/// started and hands back the reply once there is one. Empty text again means
/// the agent is still not done; a reply already written comes back at once, so
/// the action can be repeated without harm.
@available(iOS 27.0, *)
struct WaitIntent: AppIntent, LongRunningIntent, CancellableIntent {
    static let title: LocalizedStringResource = "Wait for Resident"
    static let description = IntentDescription(
        "Carries on with the last Ask Resident and returns its reply. Returns empty text if the agent needs longer still. Put it after Ask Resident, inside Repeat, for work that takes more than three minutes.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let app = AppModel.shared
        guard let id = ActionChat.id, let chat = app.chatModel(for: id) else {
            throw AskError.failed("There is nothing to wait for. Run Ask Resident first.")
        }
        if chat.modelOverride == nil, let ref = ActionChat.model, app.isAvailable(ref) { chat.modelOverride = ref }
        let reply = try await ActionRun.run(self, chat: chat) {
            // Held at the gate, the turn carries on by itself once the gate opens. One
            // that was cut off, or lost with the app, starts again from its last finished step.
            chat.resumeIfPaused()
            if !chat.isRunning { chat.continueTurn() }
        }
        return .result(value: reply)
    }
}

/// Which chat the last Ask Resident started, kept where it outlasts the app being closed.
enum ActionChat {
    static var id: UUID? { UserDefaults.standard.string(forKey: "actionChat").flatMap(UUID.init(uuidString:)) }

    /// The model that action chose, if it chose one.
    @available(iOS 27.0, *)
    static var model: ModelRef? {
        UserDefaults.standard.string(forKey: "actionChatModel").flatMap { ModelEntity(id: $0, name: "").ref }
    }

    static func remember(_ id: UUID, model: String?) {
        UserDefaults.standard.set(id.uuidString, forKey: "actionChat")
        UserDefaults.standard.set(model, forKey: "actionChatModel")
    }
}

/// What both actions do: give the chat's turn time to run, show its progress, and
/// hand over when Shortcuts is about to stop waiting.
@available(iOS 27.0, *)
enum ActionRun {
    /// How long one action lets the agent work. Shortcuts stops waiting after about four minutes.
    static let handOverSeconds: TimeInterval = 180

    /// Starts or carries on the turn with `begin` and returns the reply as plain
    /// text, or empty text when the turn was held for the next action.
    @MainActor
    static func run<Action: LongRunningIntent & CancellableIntent>(
        _ action: Action, chat: ChatModel, begin: @escaping @MainActor () -> Void
    ) async throws -> String {
        let app = AppModel.shared
        let progress = action.progress
        // Progress is the agent's steps: each reply or tool call it makes is one.
        // It also creeps forward inside a step. iOS lets a long action carry on for
        // as long as it shows progress, and a model's first step from cold can take
        // more than the 30 seconds an action is otherwise given.
        let limit = 8
        let scale = 1000.0
        progress.totalUnitCount = Int64(Double(limit) * scale)
        let turnStart = chat.conversation.messages.lastIndex { $0.role == .user } ?? chat.conversation.messages.count
        let watcher = Task { @MainActor in
            var lastSteps = -1
            var stepBegan = Date()
            while !Task.isCancelled {
                let steps = min(limit - 1, chat.conversation.messages.dropFirst(turnStart).filter { $0.role == .assistant }.count)
                if steps != lastSteps {
                    lastSteps = steps
                    stepBegan = Date()
                }
                // Most of the way through a step's share after a minute, never all of it.
                let within = 1 - exp(-Date().timeIntervalSince(stepBegan) / 30)
                progress.completedUnitCount = max(progress.completedUnitCount, Int64((Double(steps) + 0.95 * within) * scale))
                // The Live Activity shows these two lines: say what the agent is doing, not a count.
                progress.localizedDescription = chat.activity ?? "Working"
                progress.localizedAdditionalDescription = steps == 0 ? "Starting" : "Step \(steps + 1)"
                try? await Task.sleep(for: .seconds(1))
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
        let name = String(describing: Action.self)
        IntentLog.note("\(name): model \(isLocal ? "local" : "other"), gpu wanted \(wantsGPU), turn running \(chat.isRunning)")
        let work: (LongRunningTaskOptions) async throws -> Bool = { options in
            try await action.performBackgroundTask(
                options: options,
                operation: {
                    started.mark()
                    // An action runs with the app off screen: nothing may stay held from when the app was last left.
                    GenerationGate.open()
                    await begin()
                    let done = await chat.waitForTurn(upTo: handOverSeconds)
                    // Not done: hold the model between two tokens, so the next action carries on from this word.
                    if !done, isLocal { GenerationGate.close() }
                    return done
                },
                onCancel: { reason in
                    started.cancelled(reason.debugDescription)
                    IntentLog.note("cancelled by iOS: \(reason.debugDescription)")
                    Task { @MainActor in chat.stop() }
                })
        }
        let done: Bool
        do {
            done = try await work(wantsGPU ? [.requiresGPU] : [])
        } catch where wantsGPU && !started.value {
            // Refused before it began, as a build without the entitlement is: run with what every app gets.
            IntentLog.note("gpu task refused: \(error)")
            done = try await work([])
        } catch {
            IntentLog.note("failed: \(error)")
            throw error
        }
        let reply = chat.lastReply
        IntentLog.note("\(name) ended: done \(done), reply \(reply.map { "\($0.count) characters" } ?? "none"), paused \(chat.pausedForBackground), error \(chat.errorMessage ?? "none")")
        // Held for the next action, or stopped by iOS taking the GPU: either way Wait for Resident carries on.
        guard done, !chat.pausedForBackground else { return "" }
        progress.completedUnitCount = progress.totalUnitCount
        if reply == nil, let reason = started.cancelReason {
            throw AskError.failed(
                reason.lowercased().contains("timeout")
                    ? "iOS stopped the action for taking too long before the agent had replied. The chat is in Resident: open it to carry on."
                    : "The action was stopped before the agent replied.")
        }
        if let error = chat.errorMessage, reply == nil { throw AskError.failed(error) }
        guard let reply else { throw AskError.failed("The agent gave no reply.") }
        return AskIntent.plainText(reply)
    }
}

/// Whether the action's work has begun, which decides if it is safe to start it a second time.
private final class Started: @unchecked Sendable {
    private let lock = NSLock()
    private var began = false
    private var reason: String?
    var value: Bool { lock.withLock { began } }
    /// Why iOS cancelled the action, if it did.
    var cancelReason: String? { lock.withLock { reason } }
    func mark() { lock.withLock { began = true } }
    func cancelled(_ why: String) { lock.withLock { reason = why } }
}

/// A short record of what the last few actions did, kept beside the app's data.
/// An action runs where nothing can be seen, so this is how a failure is read afterwards.
enum IntentLog {
    private static let lock = NSLock()
    private static var file: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Harness/intent-log.txt")
    }

    static func note(_ text: String) {
        lock.withLock {
            guard let file else { return }
            var lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }
            lines.append("\(ISO8601DateFormatter().string(from: Date())) \(text)")
            try? lines.suffix(200).joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }
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
