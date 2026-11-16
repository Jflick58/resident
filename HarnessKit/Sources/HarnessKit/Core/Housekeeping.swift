import Foundation

/// Small jobs the harness does around a chat with the model's help, each as a
/// short request of its own, so the model answering the user does not have to
/// remember to do them.
///
/// A small model given a question and a fact in one message answers the
/// question and lets the fact go by. Asked only "is there a fact here?", it
/// finds it.
public enum Housekeeping {
    /// One short answer from the model, with no tools and no thinking.
    static func ask(_ provider: any ModelProvider, system: String, user: String, maxOutputTokens: Int) async -> String? {
        let agent = Agent(
            provider: provider, tools: [],
            options: GenerationOptions(maxOutputTokens: maxOutputTokens, temperature: 0.2, thinking: .off), maxSteps: 1)
        var answer: String?
        do {
            for try await event in agent.run(messages: [.system(system), .user(user)]) {
                if case .assistantMessage(let message) = event { answer = message.text }
            }
        } catch {
            return nil
        }
        return answer?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Memory

    static let memoryInstructions = """
        You read one message that a person wrote to their assistant and pick out lasting facts about that person: \
        things that will still be true weeks from now. Facts are about who they are, where they live or work, \
        their family and the people in their life, their health and diet, and how they like to be answered.
        What they are asking for is not a fact about them. Most messages contain no fact.

        Reply with one line per fact, starting with "- The user". If there is no fact, reply NONE.

        Message: I'm allergic to shellfish, what can I order at a sushi place?
        - The user is allergic to shellfish.

        Message: What's the weather in Paris tomorrow?
        NONE

        Message: Can you help me write a cover letter for a design job?
        NONE

        Message: Keep it short please, I prefer bullet points.
        - The user prefers short answers in bullet points.

        Message: My wife Ana and I are planning a trip to Japan, any ideas?
        - The user's wife is called Ana.

        Message: I didn't like that answer, try again.
        NONE
        """

    public struct MemoryUpdate: Equatable, Sendable {
        public var facts: [String] = []
        public var forget: [String] = []
        public var isEmpty: Bool { facts.isEmpty && forget.isEmpty }
    }

    /// Whether a message is worth a memory pass at all. Most are not, and skipping
    /// them costs nothing: a fact about oneself needs "I", "my" or "me" to say.
    public static func mightHoldAFact(_ message: String) -> Bool {
        let words = message.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }).map(String.init)
        guard words.count >= 4 else { return false }
        let firstPerson: Set<String> = ["i", "i'm", "i’m", "i've", "i’ve", "im", "my", "me", "we", "we're", "we’re", "our", "mine"]
        return words.contains(where: firstPerson.contains)
    }

    /// Reads one message from the user for lasting facts about them.
    ///
    /// The model is not shown what is already known: shown the list, a small
    /// model repeats and rewrites it. What is new and what an old fact is
    /// replaced by are worked out here from the words.
    public static func memoryUpdate(from message: String, known: [String], provider: any ModelProvider) async -> MemoryUpdate {
        guard mightHoldAFact(message) else { return MemoryUpdate() }
        guard
            let reply = await ask(
                provider, system: memoryInstructions, user: "Message: " + String(message.prefix(1200)), maxOutputTokens: 120)
        else { return MemoryUpdate() }
        return parseMemoryUpdate(reply, known: known, message: message)
    }

    /// The words of a fact that carry its meaning.
    static func keyWords(_ fact: String) -> Set<String> {
        let dull: Set<String> = [
            "the", "user", "users", "is", "are", "was", "has", "have", "and", "not", "now", "they", "their", "any", "more",
            "anymore", "longer", "called", "named", "with", "that", "for", "from",
        ]
        return Set(
            fact.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                .map { $0.count > 4 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 }
                .filter { $0.count > 2 && !dull.contains($0) })
    }

    /// Openings that mean the model wrote down the request, not a fact.
    private static let requestOpenings = [
        "the user wants", "the user is asking", "the user asked", "the user needs", "the user would like", "the user is looking",
        "the user requests", "the user requested", "the user is planning to ask", "the user wonders",
    ]

    static func parseMemoryUpdate(_ reply: String, known: [String], message: String) -> MemoryUpdate {
        var update = MemoryUpdate()
        let said = keyWords(message)
        for raw in reply.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            let fact = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            let lowered = fact.lowercased()
            // A plain sentence about the user, and not the request written back.
            guard fact.count >= 12, fact.count <= 160, lowered.hasPrefix("the user"), !fact.contains("("), !fact.contains(":"),
                !requestOpenings.contains(where: lowered.hasPrefix)
            else { continue }
            let words = keyWords(fact)
            // Made of the message's own words. A fact with other words in it came
            // from somewhere else, usually the examples in the instructions.
            guard !words.isEmpty, Double(words.intersection(said).count) / Double(words.count) >= 0.6 else { continue }
            // Not the fact before it, said another way.
            if update.facts.contains(where: { earlier in
                let other = keyWords(earlier)
                return Double(words.intersection(other).count) / Double(min(words.count, other.count)) >= 0.6
            }) { continue }
            // Says nothing an old fact does not already say.
            if known.contains(where: { words.isSubset(of: keyWords($0)) }) { continue }
            // Covers an old fact and adds to it or turns it round: the old one goes.
            for old in known {
                let oldWords = keyWords(old)
                if !oldWords.isEmpty, oldWords.isSubset(of: words), !update.forget.contains(old) { update.forget.append(old) }
            }
            update.facts.append(fact)
        }
        // More than a couple from one message is the model listing the message back.
        update.facts = Array(update.facts.prefix(3))
        return update
    }

    // MARK: Summaries

    /// Turns of a chat as plain text for summarising: what was said, and which
    /// tools were used, without what the tools returned.
    static func script(_ messages: [Message], limit: Int) -> String {
        var lines: [String] = []
        for message in messages {
            switch message.role {
            case .user:
                lines.append("User: " + String(message.text.prefix(600)))
            case .assistant:
                if !message.text.isEmpty { lines.append("Assistant: " + String(message.text.prefix(900))) }
                for call in message.toolCalls { lines.append("(Assistant used \(call.name))") }
            case .system, .tool:
                continue
            }
        }
        let text = lines.joined(separator: "\n")
        // The end of a long stretch matters more than its start.
        return text.count > limit ? "…" + String(text.suffix(limit)) : text
    }

    /// A short account of the older part of a chat, to stand in for it.
    /// `previous` is the summary so far, when the chat has been summarised before.
    public static func summary(of messages: [Message], previous: String?, provider: any ModelProvider) async -> String? {
        let system = """
            Summarise the earlier part of a conversation between a user and their assistant, so the assistant can \
            carry on without rereading it. In under 150 words, as short plain sentences, say: what the user wanted, \
            what was found or decided, and any names, numbers, ids or preferences that later messages may refer to. \
            Leave out greetings and how the answer was reached. Call them "the user" and "the assistant". \
            Reply with the summary only.
            """
        var user = ""
        if let previous, !previous.isEmpty { user += "Summary so far:\n\(previous)\n\nWhat came next:\n" }
        user += script(messages, limit: 6000)
        guard var reply = await ask(provider, system: system, user: user, maxOutputTokens: 420), reply.count >= 40 else { return nil }
        reply = String(reply.prefix(1600))
        // Cut short by a limit: end at the last whole sentence.
        if let last = reply.last, !".!?".contains(last), let end = reply.lastIndex(where: { ".!?".contains($0) }) {
            reply = String(reply[...end])
        }
        return reply
    }

    // MARK: Skills

    /// A turn worth offering to save as a skill: it took this many tool calls,
    /// so there was a way of doing it to work out. (Hermes Agent draws the line
    /// at five; these models take fewer steps over the same work.)
    public static let skillWorthyToolCalls = 3

    /// Drafts a skill from one finished turn: what was asked, the tools used in
    /// order, and how it ended. The user sees and edits the draft before it is saved.
    public static func skillDraft(from turn: [Message], provider: any ModelProvider) async -> Skill? {
        guard let request = turn.first(where: { $0.role == .user }) else { return nil }
        var steps: [String] = []
        for message in turn where message.role == .assistant {
            for call in message.toolCalls {
                // The tool and the gist of what it was asked, not the call itself: shown
                // the JSON, the model copies it out as the steps.
                let gist = call.arguments.objectValue?.values.compactMap(\.stringValue).first.map { String($0.prefix(60)) } ?? ""
                steps.append("\(steps.count + 1). \(call.name)\(gist.isEmpty ? "" : " for \"" + gist + "\"")")
            }
        }
        let answer = turn.last { $0.role == .assistant && !$0.text.isEmpty }?.text ?? ""
        let system = """
            An assistant has just finished a task. Write instructions so it can do the same kind of task again \
            without working it out afresh. Make them general: about this kind of request, not this one's details.

            Reply in exactly this form:
            NAME: two or three lowercase words joined by hyphens
            WHEN: one line saying when to use these instructions
            STEPS:
            1. first step
            2. next step

            Each step is a plain sentence telling the assistant what to do, naming the tool to use. Use at most \
            five steps, and say how to present the answer in the last one. Do not copy the tool calls.

            Example, for a task where the user asked what a phone costs at three shops:
            NAME: compare-prices
            WHEN: The user asks to compare the price of a product across shops
            STEPS:
            1. Search the web once for each shop with web_search.
            2. Open the best result for each shop with fetch_page and read the price.
            3. If a price is missing or unclear, search once more for that shop only.
            4. Answer with one line per shop, cheapest first.
            """
        let user = """
            The user asked: \(request.text.prefix(500))

            Tool calls the assistant made, in order:
            \(steps.prefix(14).joined(separator: "\n"))

            How its answer began: \(answer.prefix(400))
            """
        guard let reply = await ask(provider, system: system, user: user, maxOutputTokens: 320) else { return nil }
        return parseSkillDraft(reply)
    }

    static func parseSkillDraft(_ reply: String) -> Skill? {
        var name = ""
        var when = ""
        var steps: [String] = []
        var inSteps = false
        for raw in reply.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " *#"))
            let upper = line.uppercased()
            if upper.hasPrefix("NAME:") {
                name = Skill.slug(String(line.dropFirst(5)))
            } else if upper.hasPrefix("WHEN:") {
                when = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            } else if upper.hasPrefix("STEPS:") {
                inSteps = true
                let rest = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { steps.append(rest) }
            } else if inSteps, !line.isEmpty, !line.contains("{") {
                steps.append(line)
            }
        }
        guard !name.isEmpty, name != "compare-prices", !when.isEmpty, steps.count >= 2 else { return nil }
        return Skill(
            name: String(name.prefix(40)), summary: String(when.prefix(160)),
            instructions: steps.prefix(8).joined(separator: "\n"))
    }

    // MARK: Titles

    /// A few words naming a chat, from how it began.
    public static func title(question: String, answer: String, provider: any ModelProvider) async -> String? {
        let system = """
            Name this conversation in 2 to 5 words, like a subject line. Reply with the name only: \
            no quotes, no full stop, no explanation.
            """
        let user = "The user wrote:\n\(question.prefix(600))\n\nThe assistant answered:\n\(answer.prefix(600))"
        guard let reply = await ask(provider, system: system, user: user, maxOutputTokens: 24) else { return nil }
        return cleanTitle(reply)
    }

    static func cleanTitle(_ reply: String) -> String? {
        var title = reply.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’*#.:-"))
        if title.lowercased().hasPrefix("title") { title = title.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " :-\"")) }
        let words = title.split(separator: " ")
        guard !title.isEmpty, words.count <= 8, title.count <= 60 else { return nil }
        return title
    }
}
