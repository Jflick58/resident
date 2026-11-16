import Foundation

/// Tidies model output that leaks protocol markup into the answer. Small models
/// and older servers do this in a few predictable ways; fixing it here keeps
/// every provider's output clean in the transcript.
public enum OutputCleaner {
    public struct Cleaned: Equatable, Sendable {
        public var reasoning: String
        public var text: String
    }

    /// - A closing `</think>` with no opening tag means everything before it was
    ///   thinking. Some servers start the reply mid-thought.
    /// - A `<final_answer>` block that repeats an answer already given is
    ///   dropped; one that holds the only answer is unwrapped.
    public static func clean(text: String, reasoning: String = "") -> Cleaned {
        var reasoning = reasoning
        var text = text

        if let close = text.range(of: "</think>") {
            let leaked = String(text[..<close.lowerBound]).replacingOccurrences(of: "<think>", with: "")
            let leakedTrimmed = leaked.trimmingCharacters(in: .whitespacesAndNewlines)
            if !leakedTrimmed.isEmpty {
                reasoning = reasoning.isEmpty ? leakedTrimmed : reasoning + "\n" + leakedTrimmed
            }
            text = String(text[close.upperBound...])
        }

        if let open = text.range(of: "<final_answer>") {
            let before = text[..<open.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            var inner = String(text[open.upperBound...])
            if let close = inner.range(of: "</final_answer>") { inner = String(inner[..<close.lowerBound]) }
            text = before.isEmpty ? inner : before
        }
        text = text.replacingOccurrences(of: "</final_answer>", with: "")

        return Cleaned(
            reasoning: reasoning.trimmingCharacters(in: .whitespacesAndNewlines),
            text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
