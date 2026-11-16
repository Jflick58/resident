import Foundation

/// A connector whose tools stay out of the prompt until a request needs them.
///
/// A small model chooses well among a dozen tools and badly among fifty, and
/// fifty definitions would fill its context before the conversation starts. So
/// only the basic tools are declared from the start. Every connector is shown
/// to the model as one line, and its tools are declared only once the model
/// opens it (or the user names it).
public struct ToolGroup: Sendable {
    /// A connector with this many tools or fewer is opened whole.
    public static let wholeLimit = 8
    /// How many tools of a larger connector one opening brings in.
    public static let perOpen = 6
    /// How many tools a new message may add to a connector the chat already uses.
    public static let perRefresh = 3
    /// Connector tools declared at once. Beyond this, the least recently used go back.
    public static let loadedLimit = 12
    /// The share of the context that declared connector tools may take.
    public static let contextShare = 0.25
    /// The most tokens of connector tools declared at once, however large the context.
    public static let budgetLimit = 4000
    /// The least, however small the context: under this, a connector with large
    /// tools (Linear's run to 500 tokens each) opens two at a time, too few to work with.
    public static let budgetFloor = 2500
    /// The tool the model calls to open a connector.
    public static let openerName = "use_connector"

    /// What the model calls it, e.g. "linear". Also the prefix of its tools' names.
    public var name: String
    /// What the user calls it, e.g. "Linear".
    public var title: String
    /// What it is for, in a few words. May be empty.
    public var summary: String
    public var tools: [any Tool]
    /// The service's own notes on using its tools. Given to the model when it
    /// opens the connector, shortened to `guidanceLimit`.
    public var guidance: String
    public static let guidanceLimit = 900

    public init(name: String, title: String, summary: String = "", tools: [any Tool], guidance: String = "") {
        self.name = name
        self.title = title
        self.summary = summary
        self.tools = tools
        self.guidance = guidance
    }

    /// The connector's line in the system prompt: its purpose and a taste of its tools.
    public var promptLine: String {
        let names = tools.map(\.spec.name)
        var line = "- \(name): "
        let purpose = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !purpose.isEmpty { line += purpose.hasSuffix(".") ? purpose + " " : purpose + ". " }
        line += "Tools: " + names.prefix(10).joined(separator: ", ")
        if names.count > 10 { line += " and \(names.count - 10) more" }
        return line
    }

    /// The lines added to the system prompt, or nil when no connector is held back.
    public static func promptSection(_ groups: [ToolGroup]) -> String? {
        let groups = groups.filter { !$0.tools.isEmpty }
        guard !groups.isEmpty else { return nil }
        return
            "Connectors hold more tools. To use one, call \(openerName) with its name and what you need to do, then call the tools it gives you:\n"
            + groups.map(\.promptLine).joined(separator: "\n")
    }

    /// The tools that best fit a need, best first. A small connector comes whole.
    ///
    /// `need` is what the model said it wants; `request` is the user's message,
    /// which counts for a quarter as much: it helps when the model describes its need
    /// badly, and misleads when it holds a word about something else ("run my
    /// tickets skill" is not asking for Linear's agent-skill tools).
    ///
    /// With `matchingOnly`, tools that no word of the need or request points to are left out.
    public func pick(_ need: String, request: String = "", matchingOnly: Bool = false) -> [any Tool] {
        guard tools.count > Self.wholeLimit else { return tools }
        var query: [String: Double] = [:]
        for term in Self.expand(Self.terms(request)) { query[term] = 0.25 }
        for term in Self.expand(Self.terms(need)) { query[term] = 1 }
        // An identifier in the text ("ENG-412") means one particular thing is wanted: fetch it.
        if (need + " " + request).range(of: #"\b[A-Z][A-Z0-9]{1,9}-\d+\b"#, options: .regularExpression) != nil {
            query["get"] = 1
        } else if let weight = query["get"], !(need + " " + request).lowercased().contains("get_") {
            // With nothing particular named, "get my open tickets" asks for a list. Left as
            // "get", it brought Linear's six get_ tools and not list_issues, and LFM3
            // spent ten steps trying to list issues with tools that fetch one thing.
            query["get"] = nil
            query["list"] = max(query["list"] ?? 0, weight)
        }
        // Its own name says nothing about which of its tools is wanted.
        for term in Self.terms(name) + Self.terms(title) { query[term] = nil }
        var scores = scores(for: query)
        let matched = scores.map { $0 > 0 }

        // What most of the tools are about is what the connector is for: Linear's
        // are mostly about issues. When the words of the need pick nothing out,
        // the tools about that come first, not whichever the service listed first.
        let names = tools.map { Set(Self.terms(ownName($0))) }
        var frequency: [String: Int] = [:]
        for terms in names { for term in terms where !Self.verbs.contains(term) { frequency[term, default: 0] += 1 } }
        let most = Double(frequency.values.max() ?? 1)
        for index in tools.indices {
            let central = names[index].map { Double(frequency[$0] ?? 0) / most }.max() ?? 0
            // Reading tools before writing ones, among the central.
            let reads = names[index].contains { ["list", "search", "get", "find"].contains($0) }
            scores[index] += 0.5 * central + (reads ? 0.1 : 0)
            // Named in full by the need ("list issues" for list_issues): that is the one asked for,
            // ahead of others that share its words (list_issue_labels).
            if !names[index].isEmpty, names[index].allSatisfy({ query[$0] == 1 }) { scores[index] += 3 }
        }
        // Ties keep the connector's own order.
        let order = tools.indices.sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }
        return order.filter { !matchingOnly || matched[$0] }.prefix(Self.perOpen).map { tools[$0] }
    }

    /// A tool's name without the connector's prefix.
    private func ownName(_ tool: any Tool) -> String {
        let full = tool.spec.name
        return full.lowercased().hasPrefix(name + "_") ? String(full.dropFirst(name.count + 1)) : full
    }

    /// How well each tool fits the words of a need, each word with its weight.
    private func scores(for query: [String: Double]) -> [Double] {
        let entries = tools.map { tool -> (name: Set<String>, text: Set<String>) in
            (Set(Self.terms(ownName(tool))), Set(Self.terms(tool.spec.description)))
        }
        let count = Double(tools.count)
        var scores = [Double](repeating: 0, count: tools.count)
        for (term, importance) in query {
            let frequency = Double(entries.filter { $0.name.contains(term) || $0.text.contains(term) }.count)
            guard frequency > 0 else { continue }
            // A word few tools share says more than one they all share.
            let weight = importance * log(1 + (count - frequency + 0.5) / (frequency + 0.5))
            for index in entries.indices {
                if entries[index].name.contains(term) { scores[index] += 3 * weight }
                if entries[index].text.contains(term) { scores[index] += weight }
            }
        }
        return scores
    }

    /// Words people use for what services call something else.
    private static let synonyms: [String: [String]] = [
        "ticket": ["issue"], "task": ["issue"], "bug": ["issue"], "story": ["issue"], "todo": ["issue", "reminder"],
        "doc": ["document", "page"], "note": ["document", "page"], "mail": ["email", "message"], "email": ["message"],
        "meeting": ["event"], "appointment": ["event"], "repo": ["repository"], "pr": ["pull"], "person": ["user"],
        "people": ["user"], "teammate": ["user"], "sprint": ["cycle"], "status": ["state"], "show": ["list"], "find": ["search", "list"],
        "check": ["list"], "create": ["save"], "add": ["save", "create"], "update": ["save"], "edit": ["save"], "change": ["save"],
        "mark": ["save"], "move": ["save"], "assign": ["save"], "close": ["save"],
    ]

    /// Verbs that tool names start with, which say nothing of what a connector is about.
    private static let verbs: Set<String> = [
        "list", "get", "save", "create", "delete", "update", "search", "find", "add", "remove", "set", "read", "write", "mark",
    ]

    /// The terms and what else they may be called.
    static func expand(_ terms: [String]) -> [String] {
        terms + terms.flatMap { synonyms[$0] ?? [] }
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "of", "to", "in", "on", "for", "and", "or", "is", "are", "my", "me", "i", "it", "do", "does",
        "what", "how", "any", "at", "from", "with", "that", "this", "have", "has", "will", "be", "use", "user", "s",
        "please", "can", "you", "need", "want",
    ]

    static func terms(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).compactMap { word in
            var term = String(word)
            if term.count > 3, term.hasSuffix("s") { term.removeLast() }
            return stopWords.contains(term) ? nil : term
        }
    }
}

/// Which connector tools are declared to the model right now.
struct ToolShelf {
    let groups: [ToolGroup]
    /// Names of the declared connector tools, in the order they were declared.
    /// The order is kept stable so the model's cache of the prompt survives.
    private(set) var loaded: [String]
    private var lastUsed: [String: Int] = [:]
    private var clock = 0
    private let toolsByName: [String: any Tool]
    /// Tokens that declared connector tools may take in total.
    private let budget: Int
    private var cost: [String: Int] = [:]

    init(groups: [ToolGroup], loaded: [String] = [], contextTokens: Int = 16384) {
        self.groups = groups.filter { !$0.tools.isEmpty }
        budget = min(ToolGroup.budgetLimit, max(ToolGroup.budgetFloor, Int(Double(contextTokens) * ToolGroup.contextShare)))
        toolsByName = Dictionary(
            self.groups.flatMap { $0.tools.map { ($0.spec.name, $0) } }, uniquingKeysWith: { first, _ in first })
        self.loaded = []
        add(loaded.filter { toolsByName[$0] != nil })
    }

    var isEmpty: Bool { groups.isEmpty }
    var allTools: [any Tool] { groups.flatMap(\.tools) }
    var loadedSpecs: [ToolSpec] { loaded.compactMap { toolsByName[$0]?.spec } }

    func holds(_ name: String) -> Bool { toolsByName[name] != nil }

    var spec: ToolSpec {
        ToolSpec(
            name: ToolGroup.openerName,
            description: "Open a connector to get its tools. Returns the names of tools you can then call.",
            parameters: [
                "type": "object",
                "properties": [
                    "connector": ["type": "string", "enum": .array(groups.map { .string($0.name) })],
                    "need": ["type": "string", "description": "What you need to do, in a few words"],
                ],
                "required": ["connector"],
            ])
    }

    func group(named text: String) -> ToolGroup? {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        return groups.first { $0.name == wanted || $0.title.lowercased() == wanted }
            ?? groups.first { $0.name.contains(wanted) || wanted.contains($0.name) }
    }

    /// Answers a call to the opener: declares the connector's tools that fit the need.
    mutating func open(_ arguments: JSONValue, request: String) -> ToolResult {
        guard let group = group(named: arguments["connector"]?.stringValue ?? "") else {
            return .error("There is no connector with that name. The connectors are: \(groups.map(\.name).joined(separator: ", ")).")
        }
        let picked = affordable(group.pick(arguments["need"]?.stringValue ?? "", request: request).map(\.spec.name))
        add(picked)
        let rest = group.tools.map(\.spec.name).filter { !loaded.contains($0) }
        var text = "\(group.title) tools you can call now: \(picked.joined(separator: ", "))."
        if !rest.isEmpty {
            text += "\nNot loaded yet: \(rest.prefix(30).joined(separator: ", "))\(rest.count > 30 ? " and more" : "")."
                + " To get one of these, call \(ToolGroup.openerName) again and name it in need."
        }
        let notes = group.guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            text += "\nHow \(group.title) says to use its tools: " + SchemaTrim.shorten(notes, to: ToolGroup.guidanceLimit)
        }
        return ToolResult(text)
    }

    /// Opens connectors the user named in their message. True when that declared something new.
    ///
    /// A connector called by an ordinary word (Home, Mail, Notes) is sometimes
    /// opened when the word was only said in passing. Requiring the rest of the
    /// message to fit the connector was tried and cost more than it saved:
    /// "Move ENG-431 to Done in Linear" shares no word with Linear's tools.
    mutating func preload(for message: String) -> Bool {
        let words = Set(message.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let before = loaded
        for group in groups {
            let title = group.title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            guard !title.isEmpty, title.allSatisfy(words.contains) else { continue }
            add(affordable(group.pick(message).map(\.spec.name)))
        }
        return loaded != before
    }

    /// Notes that a declared tool was called earlier in the chat, so it outlasts ones that never were.
    mutating func touch(_ name: String) {
        guard loaded.contains(name) else { return }
        clock += 1
        lastUsed[name] = clock
    }

    /// Fits connectors already in use to a new message. True when that declared something new.
    ///
    /// The tools declared for "what are my urgent tickets" are all for reading.
    /// Asked next to "close the first one", a small model looks at what it has,
    /// finds nothing that writes, and says it cannot (Apple's model, 3 chats in 3)
    /// when it could have opened the connector again. So each new message picks
    /// again from the connectors the chat is already using, taking only tools
    /// its words point to: "Thanks" changes nothing.
    mutating func refresh(for message: String) -> Bool {
        let before = loaded
        for group in groups where group.tools.contains(where: { loaded.contains($0.spec.name) }) {
            add(affordable(group.pick("", request: message, matchingOnly: true).prefix(ToolGroup.perRefresh).map(\.spec.name)))
        }
        return loaded != before
    }

    /// Declares connector tools that the text names outright, such as a skill's
    /// instructions saying "use linear_list_issues". Told the name, the model
    /// should not have to search for the tool. True when that declared something new.
    mutating func loadNamed(in text: String, request: String) -> Bool {
        let before = loaded
        for name in toolsByName.keys.sorted() where !loaded.contains(name) && text.contains(name) {
            _ = use(name, request: request)
        }
        return loaded != before
    }

    /// Notes that a tool was called, declaring it if it was not. True when it was newly declared.
    ///
    /// A model that calls a connector's tool by name has not seen the rest of
    /// the connector, so the tools that fit the request are declared with it.
    mutating func use(_ name: String, request: String = "") -> Bool {
        guard holds(name) else { return false }
        let isNew = !loaded.contains(name)
        if isNew, let group = groups.first(where: { $0.tools.contains { $0.spec.name == name } }) {
            add(affordable(group.pick("", request: request).map(\.spec.name)))
        }
        add([name])
        return isNew
    }

    private mutating func tokens(_ name: String) -> Int {
        if let known = cost[name] { return known }
        let value = toolsByName[name]?.spec.estimatedTokens ?? 0
        cost[name] = value
        return value
    }

    /// The best-ranked of these that fit in one opening: most of the budget, and always at least one.
    private mutating func affordable(_ names: [String]) -> [String] {
        var kept: [String] = []
        var total = 0
        for name in names {
            total += tokens(name)
            if !kept.isEmpty, total > budget * 3 / 4 { break }
            kept.append(name)
        }
        return kept
    }

    private mutating func add(_ names: [String]) {
        for name in names {
            clock += 1
            lastUsed[name] = clock
            if !loaded.contains(name) { loaded.append(name) }
        }
        while loaded.count > ToolGroup.loadedLimit || loaded.reduce(0, { $0 + tokens($1) }) > budget {
            guard let oldest = loaded.filter({ !names.contains($0) }).min(by: { lastUsed[$0, default: 0] < lastUsed[$1, default: 0] })
            else { break }
            loaded.removeAll { $0 == oldest }
        }
    }
}
