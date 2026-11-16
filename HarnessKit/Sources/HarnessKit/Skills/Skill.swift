import Foundation

/// A skill: instructions for one kind of task, loaded only when a task calls
/// for it. The model always sees each skill's name and one line on when to use
/// it; the instructions themselves cost nothing until `use_skill` fetches them.
public struct Skill: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Short lowercase name the model uses to load it, e.g. `write-email`.
    public var name: String
    /// One line on when to use it.
    public var summary: String
    public var instructions: String
    public var isEnabled: Bool
    public var isBuiltIn: Bool

    public init(
        id: UUID = UUID(), name: String, summary: String, instructions: String, isEnabled: Bool = true,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.instructions = instructions
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
    }

    /// A name in the form the model is shown: lowercase words joined by hyphens.
    public static func slug(_ text: String) -> String {
        let mapped = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(mapped).split(separator: " ").joined(separator: "-")
    }

    /// Reads a `SKILL.md`: optional front matter with `name` and `description`, then the instructions.
    public static func parse(markdown: String, fallbackName: String = "skill") -> Skill {
        var name = fallbackName
        var summary = ""
        var body = markdown
        let lines = markdown.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
            let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        {
            for line in lines[1..<end] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if key == "name", !value.isEmpty { name = value }
                if key == "description" { summary = value }
            }
            body = lines[(end + 1)...].joined(separator: "\n")
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if summary.isEmpty {
            // Without front matter, the first line of text says what the skill is for.
            let first = body.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            summary = first.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        }
        return Skill(name: slug(name), summary: String(summary.prefix(200)), instructions: body)
    }

    /// The lines added to the system prompt, or nil when there is nothing to offer.
    public static func promptSection(_ skills: [Skill]) -> String? {
        let enabled = skills.filter(\.isEnabled)
        guard !enabled.isEmpty else { return nil }
        return "Skills hold instructions for particular tasks. When a task matches one, call use_skill with its name first and follow what it returns:\n"
            + enabled.map { "- \($0.name): \($0.summary)" }.joined(separator: "\n")
    }

    /// When to save a new skill. One sentence, after Hermes Agent's ("when you
    /// work out a non-trivial workflow, record it for future reuse"), cut down to
    /// what a small model does: asked to offer a skill after a task of several
    /// steps, LFM3 never did, in three wordings; told a standing rule, it saves
    /// it. Skills from finished tasks come from the Save as Skill button instead.
    public static let savingGuidance =
        "When the user tells you how they want a kind of task done from now on, save it as a skill."

    public static let builtIns: [Skill] = [
        Skill(
            id: UUID(uuidString: "B0000000-0000-4000-8000-000000000001")!, name: "write-email",
            summary: "Drafting or replying to an email",
            instructions: """
                Write the email, do not describe it.
                1. If who it is to, or what it must achieve, is unclear, ask one short question and stop.
                2. Subject line first, on its own line, under eight words.
                3. Open with the point or the request. No "I hope this finds you well".
                4. Keep it under 120 words unless asked for more. Short paragraphs, plain words.
                5. End with the one thing you need from the reader, and by when if there is a date.
                6. Match the user's tone from the conversation; default to friendly and direct.
                Give the draft in a block the user can copy, then one line offering a change of tone or length.
                """, isBuiltIn: true),
        Skill(
            id: UUID(uuidString: "B0000000-0000-4000-8000-000000000002")!, name: "plan-day",
            summary: "Planning the user's day or week around their calendar and reminders",
            instructions: """
                1. Look at the calendar for the day or days asked about, and at open reminders, before saying anything.
                2. List fixed events in time order with their times.
                3. Fit the reminders that are due into the gaps, the most urgent first. Leave travel and meal time.
                4. Point out clashes and anything due that does not fit.
                5. Do not add or change events or reminders unless the user asks.
                Answer as a short timetable, then at most three sentences of advice.
                """, isBuiltIn: true),
        Skill(
            id: UUID(uuidString: "B0000000-0000-4000-8000-000000000003")!, name: "summarize",
            summary: "Summarizing a document, page, or long text",
            instructions: """
                1. Read all of it first. If a document was cut short, read the rest with read_document before summarizing.
                2. Start with one sentence that says what it is and its main point.
                3. Then three to six bullets: decisions, numbers, dates, names, and what is asked of the reader.
                4. Use the source's own figures and wording for facts. Do not add anything it does not say.
                5. If something important is unclear or missing in the source, say so in a last line.
                """, isBuiltIn: true),
    ]
}

/// Loads a skill's instructions for the model.
public struct UseSkillTool: Tool {
    public var skills: [Skill]

    public init(skills: [Skill]) { self.skills = skills.filter(\.isEnabled) }

    public var spec: ToolSpec {
        ToolSpec(
            name: BuiltInTool.skills.rawValue,
            description: "Load the instructions for a skill before starting a task it covers. Returns the steps to follow.",
            parameters: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "The skill's name", "enum": .array(skills.map { .string($0.name) })]
                ],
                "required": ["name"],
            ])
    }

    public func summary(for arguments: JSONValue) -> String { "Loaded a skill" }

    public func call(_ arguments: JSONValue) async -> ToolResult {
        let wanted = Skill.slug(arguments["name"]?.stringValue ?? "")
        guard let skill = skills.first(where: { $0.name == wanted }) ?? skills.first(where: { $0.name.contains(wanted) && !wanted.isEmpty })
        else {
            return .error("There is no skill named '\(wanted)'. The skills are: \(skills.map(\.name).joined(separator: ", ")).")
        }
        return ToolResult("Instructions for \(skill.name):\n\(skill.instructions)")
    }
}

/// Lets the model propose a skill. Nothing is saved unless the user agrees:
/// a skill steers every later chat it matches, and a small model's draft of one
/// is worth a look first.
public struct SaveSkillTool: Tool {
    public static let name = "save_skill"

    /// Shows the proposed skill to the user. Returns it as they approved it, or nil if they declined.
    private let approve: @Sendable (Skill) async -> Skill?

    /// The skills there already are. Saving under one of their names is taken as a change to it.
    private let existing: [Skill]

    public init(existing: [Skill] = [], approve: @escaping @Sendable (Skill) async -> Skill?) {
        self.existing = existing
        self.approve = approve
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: Self.name,
            description:
                "Save a new skill: instructions for a kind of task the user wants done the same way every time. Use it when the user asks you to save, remember or always follow a way of doing something, or agrees to your offer to. To change a skill there already is, use \(UpdateSkillTool.name) instead. The user is shown the skill and decides whether to keep it.",
            parameters: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Two or three lowercase words joined by hyphens, e.g. weekly-report"],
                    "when": ["type": "string", "description": "One line on when to use the skill"],
                    "instructions": [
                        "type": "string", "description": "The steps to follow, written as instructions to yourself, as a numbered list",
                    ],
                ],
                "required": ["name", "when", "instructions"],
            ])
    }

    public func summary(for arguments: JSONValue) -> String { "Proposed a skill" }

    public func call(_ arguments: JSONValue) async -> ToolResult {
        let name = Skill.slug(arguments["name"]?.stringValue ?? "")
        let when = (arguments["when"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = (arguments["instructions"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .error("Missing required argument: name.") }
        guard !when.isEmpty else { return .error("Missing required argument: when. Say in one line when to use the skill.") }
        guard instructions.count >= 20 else {
            return .error("The instructions are too short to be useful. Write out the steps to follow.")
        }
        let proposed = Skill(name: String(name.prefix(40)), summary: String(when.prefix(160)), instructions: instructions)
        // The name of a skill there already is: the model means to change that one,
        // and written out again from memory it loses steps (LFM3, 3 tries in 4).
        if let old = existing.first(where: { $0.name == name }) {
            return .error(
                "There is already a skill named \(old.name). To change it, call \(UpdateSkillTool.name) with its name and, in add, only the new step. For a different skill, choose another name.")
        }
        guard let saved = await approve(proposed) else {
            return ToolResult("The user looked at the skill and chose not to save it. Do not propose it again unless they ask.")
        }
        return ToolResult("Saved the skill \(saved.name). It will be offered in later chats.")
    }
}

/// Lets the model propose a change to a skill there already is. Asked to
/// "update your skill", a model with only `save_skill` writes a second skill
/// beside the first. The user sees the change and decides, as with a new one.
public struct UpdateSkillTool: Tool {
    public static let name = "update_skill"

    private let skills: [Skill]
    private let approve: @Sendable (Skill) async -> Skill?

    public init(skills: [Skill], approve: @escaping @Sendable (Skill) async -> Skill?) {
        self.skills = skills
        self.approve = approve
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: Self.name,
            description:
                "Change a skill there already is, when the user asks you to update, fix or add to it. Give only what changes: the rest of the skill is kept as it is. The user is shown the change and decides whether to keep it.",
            parameters: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "The name of the skill to change", "enum": .array(skills.map { .string($0.name) })],
                    "add": ["type": "string", "description": "The step or steps to add, written as instructions to yourself"],
                    "remove": [
                        "type": "string",
                        "description": "Text now in the skill to take out, copied exactly. With add, the new text takes its place. Leave out to only add.",
                    ],
                    "when": ["type": "string", "description": "A new line on when to use the skill. Leave out to keep the one it has."],
                ],
                "required": ["name"],
            ])
    }

    public func summary(for arguments: JSONValue) -> String { "Proposed a change to a skill" }

    public func call(_ arguments: JSONValue) async -> ToolResult {
        let wanted = Skill.slug(arguments["name"]?.stringValue ?? "")
        guard let old = skills.first(where: { $0.name == wanted }) ?? skills.first(where: { !wanted.isEmpty && $0.name.contains(wanted) })
        else {
            return .error(
                "There is no skill named '\(wanted)'. The skills are: \(skills.map(\.name).joined(separator: ", ")). For a new skill, use \(SaveSkillTool.name).")
        }
        let add = (arguments["add"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let remove = (arguments["remove"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let when = (arguments["when"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !add.isEmpty || !remove.isEmpty || !when.isEmpty else {
            return .error("Say what to change: give add, the step or steps to add to \(old.name). Its instructions are now:\n\(old.instructions)")
        }
        // The change is made here, not by the model writing the skill out again:
        // asked for the whole text, LFM3 dropped a step and added nothing, then said it had.
        var instructions = old.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remove.isEmpty {
            guard let range = instructions.range(of: remove) else {
                return .error("The skill does not hold that text to remove. Copy it exactly from the instructions, which are now:\n\(old.instructions)")
            }
            instructions.replaceSubrange(range, with: add)
        } else if !add.isEmpty {
            guard !instructions.contains(add) else { return .error("\(old.name) already says that.") }
            instructions += "\n" + add
        }
        var proposed = old
        proposed.instructions = instructions
        if !when.isEmpty { proposed.summary = String(when.prefix(160)) }
        guard let saved = await approve(proposed) else {
            return ToolResult("The user looked at the change and chose not to keep it. The skill is as it was. Do not propose it again unless they ask.")
        }
        return ToolResult("Updated the skill \(saved.name).")
    }
}
