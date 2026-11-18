import Foundation

/// A harness preset: everything that shapes how a model behaves in a chat,
/// bundled under one name. The system prompt, the tools it may use, and how
/// hard it thinks.
public struct HarnessPreset: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var summary: String
    public var systemPrompt: String
    public var tools: [BuiltInTool]
    /// Connectors to the user's own data that this preset may use.
    public var connectors: [Connector]
    /// Connectors the user added (MCP servers) that this preset may use, by id.
    public var servers: [UUID]
    public var thinking: ThinkingLevel
    public var maxOutputTokens: Int
    /// This agent's own temperature. Nil uses the model's.
    public var temperature: Double?
    public var isBuiltIn: Bool
    /// The shape this was saved in. Before 2, every preset stored a temperature and 0.6 meant "no preference".
    /// Before 3 there were no file tools: an agent saved then gets them if it has any tools at all.
    public var version = 3

    public init(
        id: UUID = UUID(), name: String, symbol: String, summary: String, systemPrompt: String,
        tools: [BuiltInTool], connectors: [Connector] = [], servers: [UUID] = [],
        thinking: ThinkingLevel = .low,
        maxOutputTokens: Int = 2048, temperature: Double? = nil, isBuiltIn: Bool = false
    ) {
        self.connectors = connectors
        self.servers = servers
        self.id = id
        self.name = name
        self.symbol = symbol
        self.summary = summary
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.thinking = thinking
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.isBuiltIn = isBuiltIn
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        symbol = try container.decode(String.self, forKey: .symbol)
        summary = try container.decode(String.self, forKey: .summary)
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        tools = try container.decode([BuiltInTool].self, forKey: .tools)
        // Presets saved before connectors existed have none.
        connectors = try container.decodeIfPresent([Connector].self, forKey: .connectors) ?? []
        servers = try container.decodeIfPresent([UUID].self, forKey: .servers) ?? []
        thinking = try container.decode(ThinkingLevel.self, forKey: .thinking)
        maxOutputTokens = try container.decode(Int.self, forKey: .maxOutputTokens)
        let saved = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let stored = try container.decodeIfPresent(Double.self, forKey: .temperature)
        temperature = saved < 2 && stored == 0.6 ? nil : stored
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        if saved < 3, !tools.isEmpty, !connectors.contains(.files) { connectors.append(.files) }
    }

    /// Generation options for this agent on a model with the given settings.
    /// The agent's own temperature wins over the model's; the rest is the model's.
    public func options(sampling: SamplingSettings = .standard, thinking override: ThinkingLevel? = nil) -> GenerationOptions {
        GenerationOptions(
            maxOutputTokens: maxOutputTokens,
            temperature: temperature ?? sampling.temperature,
            topP: sampling.topP, repetitionPenalty: sampling.repetitionPenalty, thinking: override ?? thinking)
    }

    public var options: GenerationOptions { options() }
}

extension HarnessPreset {
    /// Instructions the built-in agents shipped with before. A saved copy still
    /// carrying one of these was never edited by the user, so it takes the current text.
    public static let earlierInstructions: [UUID: [String]] = [
        assistantID: [
            """
            You are a helpful assistant running privately on the user's device.
            Answer directly and concisely. Use Markdown when it helps.
            """
        ]
    ]

    /// This agent with the built-in instructions brought up to date, if they were never edited.
    public var withCurrentInstructions: HarnessPreset {
        guard let current = Self.builtIns.first(where: { $0.id == id }),
            Self.earlierInstructions[id]?.contains(systemPrompt) == true
        else { return self }
        var copy = self
        copy.systemPrompt = current.systemPrompt
        return copy
    }

    // Fixed identifiers so built-in presets survive app updates and chats keep pointing at them.
    public static let assistantID = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
    public static let coderID = UUID(uuidString: "A0000000-0000-4000-8000-000000000002")!
    public static let chatID = UUID(uuidString: "A0000000-0000-4000-8000-000000000003")!

    /// General agent: answers from the web when it needs current facts.
    public static let assistant = HarnessPreset(
        id: assistantID, name: "Assistant", symbol: "sparkles",
        summary: "Searches the web, checks your calendar and reminders, and remembers what you tell it.",
        systemPrompt: """
            You are a helpful assistant running privately on the user's device.
            Answer directly and concisely. Use Markdown when it helps.
            When you pass on what a tool returned, give what the user asked about in plain words and leave out internal ids and field names.
            """,
        tools: [.webSearch, .fetchPage, .runJavaScript, .saveMemory, .skills], connectors: [.calendar, .reminders, .files],
        thinking: .low, isBuiltIn: true)

    /// Coding help with a sandbox to check work.
    public static let coder = HarnessPreset(
        id: coderID, name: "Coder", symbol: "chevron.left.forwardslash.chevron.right",
        summary: "Writes and explains code, and runs JavaScript to check its work.",
        systemPrompt: """
            You are a careful programming assistant running privately on the user's device.
            Give working code in fenced blocks with the language named. Explain briefly, after the code.
            Check your logic by running it before stating a result.
            If the request is ambiguous, state your assumption and proceed.
            """,
        tools: [.runJavaScript, .webSearch, .fetchPage], connectors: [.files], thinking: .medium,
        maxOutputTokens: 4096, temperature: 0.3, isBuiltIn: true)

    /// Plain chat: nothing leaves the device and the full context goes to the conversation.
    public static let chat = HarnessPreset(
        id: chatID, name: "Chat", symbol: "bubble.left",
        summary: "Just the model. No tools, fully offline.",
        systemPrompt: """
            You are a helpful assistant running privately on the user's device.
            Answer directly and concisely. Use Markdown when it helps.
            If you are not sure of something, say so.
            """,
        tools: [], thinking: .off, isBuiltIn: true)

    public static let builtIns: [HarnessPreset] = [.assistant, .coder, .chat]
}

/// Builds the system message for a turn.
public enum PromptBuilder {
    /// The preset's instructions, the skills and connectors on offer, today's
    /// date, then saved memory. Nothing here is about a particular tool: each
    /// tool's own description says when to use it, so the prompt does not push
    /// the model towards one tool over another. Memory is the exception in kind,
    /// not in letter: it is something the agent has, like the date, and a model
    /// only keeps it up if told that doing so is its job. The date is day-granular so the prompt prefix stays stable within a day and the
    /// model's cache of it can be reused.
    /// What the app is, so a model asked what it is or where it comes from can say.
    /// Every agent gets it, the user's own included: a model left to guess names
    /// whichever company trained it, or invents an app.
    public static let about =
        "You are running in Resident, an open source app for iPhone that runs AI models entirely on the user's device. Its code is at https://github.com/jflick58/resident. Say this only when the user asks what you are, what app this is or who made it."

    public static func systemPrompt(
        preset: HarnessPreset, memory: String, skills: [Skill] = [], connectors: [ToolGroup] = [], date: Date = Date(),
        calendar: Calendar = .current, canRemember: Bool? = nil, earlier: String? = nil
    ) -> String {
        var parts = [preset.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines), about]
        if preset.tools.contains(.skills) {
            parts.append([Skill.promptSection(skills), Skill.savingGuidance].compactMap { $0 }.joined(separator: "\n"))
        }
        if let section = ToolGroup.promptSection(connectors) {
            parts.append(section)
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        parts.append("Today is \(formatter.string(from: date)).")

        let trimmedMemory = memory.trimmingCharacters(in: .whitespacesAndNewlines)
        if canRemember ?? preset.tools.contains(.saveMemory) {
            parts.append(
                """
                You have a memory: a short list of lasting facts about the user that is given to you in every chat. \
                Keeping it up is your job. Add to it without being asked whenever the user tells you something about \
                themselves that will still matter in a later chat: who they are, where they live and work, the people \
                and things in their life, what they like and dislike, and how they want you to answer. Update it when \
                they correct you. Leave out one-off requests, the task at hand and anything you looked up.
                What you know about the user:
                \(trimmedMemory.isEmpty ? "Nothing yet." : trimmedMemory)
                """)
        } else if !trimmedMemory.isEmpty {
            parts.append("What you know about the user:\n\(trimmedMemory)")
        }
        // Last, because it changes as a chat goes on and everything above it does not.
        if let earlier = earlier?.trimmingCharacters(in: .whitespacesAndNewlines), !earlier.isEmpty {
            parts.append("Earlier in this conversation, in summary (written to the user, so \"you\" there means the user):\n\(earlier)")
        }
        return parts.joined(separator: "\n\n")
    }
}
