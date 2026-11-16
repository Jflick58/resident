import Foundation

/// Long-term memory: a short plain-text list of facts about the user, kept in
/// one file. It is small on purpose, because all of it goes into every prompt.
public final class MemoryStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    /// Upper bound on stored memory so it cannot crowd out the conversation.
    public let maxCharacters: Int

    public init(url: URL, maxCharacters: Int = 2000) {
        self.url = url
        self.maxCharacters = maxCharacters
    }

    public var text: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? newValue.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public var facts: [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
            .filter { !$0.isEmpty }
    }

    /// Adds a fact. Returns false when it is already stored or memory is full.
    @discardableResult
    public func add(_ fact: String) -> AddOutcome {
        let cleaned = fact.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return .empty }
        let existing = facts
        if existing.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            return .duplicate
        }
        let updated = (existing + [cleaned]).map { "- \($0)" }.joined(separator: "\n")
        guard updated.count <= maxCharacters else { return .full }
        text = updated
        return .added
    }

    public enum AddOutcome: Sendable { case added, duplicate, full, empty }

    /// Replaces everything stored with these facts.
    public func setFacts(_ facts: [String]) {
        text = facts.map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.map { "- \($0)" }.joined(separator: "\n")
    }

    /// Removes the stored facts that this phrase describes and returns them.
    /// A fact matches when it contains the phrase, or shares most of its words.
    @discardableResult
    public func forget(_ phrase: String) -> [String] {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 })
        }
        let needle = phrase.trimmingCharacters(in: .whitespaces).lowercased()
        let wanted = words(phrase)
        guard !needle.isEmpty else { return [] }
        let existing = facts
        let removed = existing.filter { fact in
            if fact.lowercased().contains(needle) { return true }
            guard !wanted.isEmpty else { return false }
            return Double(wanted.intersection(words(fact)).count) / Double(wanted.count) >= 0.6
        }
        if !removed.isEmpty { setFacts(existing.filter { !removed.contains($0) }) }
        return removed
    }
}

public struct SaveMemoryTool: Tool {
    private let store: MemoryStore

    public init(store: MemoryStore) {
        self.store = store
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: BuiltInTool.saveMemory.rawValue,
            description:
                "Remember a lasting fact or preference about the user for future chats, as one short sentence. To correct something saved earlier, give the new `fact` and put the old one in `forget`. To only remove something the user asks you to forget, give `forget` alone.",
            parameters: [
                "type": "object",
                "properties": [
                    "fact": ["type": "string", "description": "The fact to remember, e.g. \"Prefers metric units\""],
                    "forget": ["type": "string", "description": "Words from a saved fact to remove because it is wrong, out of date, or the user wants it forgotten"],
                ],
            ])
    }

    public func summary(for arguments: JSONValue) -> String { "Saved to memory" }

    public func call(_ arguments: JSONValue) async -> ToolResult {
        let fact = arguments["fact"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        let forget = arguments["forget"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !fact.isEmpty || !forget.isEmpty else { return .error("Give `fact` to remember something, or `forget` to remove something.") }

        var notes: [String] = []
        if !forget.isEmpty {
            let removed = store.forget(forget)
            if removed.isEmpty {
                if fact.isEmpty { return .error("Nothing saved matches \"\(forget)\". Saved facts: \(store.facts.isEmpty ? "none" : store.facts.joined(separator: "; ")).") }
            } else {
                notes.append("Forgot: \(removed.joined(separator: "; ")).")
            }
        }
        if !fact.isEmpty {
            switch store.add(fact) {
            case .added: notes.append("Saved.")
            case .duplicate: notes.append("Already saved.")
            case .full: return .error("Memory is full. The user can remove old items in Settings > Memory.")
            case .empty: break
            }
        }
        return ToolResult(notes.joined(separator: " "))
    }
}
