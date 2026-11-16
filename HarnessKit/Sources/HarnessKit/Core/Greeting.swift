import Foundation

/// The line a new chat opens with: the time of day, and the user's name once memory holds it.
public enum Greeting {
    /// The user's first name, if a saved fact states it.
    public static func name(in facts: [String]) -> String? {
        let patterns = [#"(?i)\bname is ([\p{Lu}][\p{L}'’-]+)"#, #"(?i)\b(?:goes by|is called|is named) ([\p{Lu}][\p{L}'’-]+)"#]
        for fact in facts {
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern),
                    let match = regex.firstMatch(in: fact, range: NSRange(fact.startIndex..., in: fact)),
                    let range = Range(match.range(at: 1), in: fact)
                else { continue }
                // A fact about someone else's name ("The user's daughter's name is…") is not theirs.
                let before = fact[..<range.lowerBound].lowercased()
                let others = ["daughter", "son", "wife", "husband", "partner", "dog", "cat", "boss", "friend", "mother", "father", "brother", "sister"]
                if others.contains(where: before.contains) { continue }
                return String(fact[range])
            }
        }
        return nil
    }

    /// A greeting for this moment. It changes with the part of the day and, a little, from day to day.
    public static func line(name: String? = nil, date: Date = Date(), calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let day = calendar.ordinality(of: .day, in: .year, for: date) ?? 0
        let phrases: [String]
        var asks = false
        switch hour {
        case 5..<12: phrases = ["Good morning"]
        case 12..<17: phrases = ["Good afternoon"]
        case 17..<23: phrases = ["Good evening"]
        default:
            phrases = ["Up late", "Still up"]
            asks = true
        }
        let phrase = phrases[day % phrases.count]
        guard let name, !name.isEmpty else { return phrase + (asks ? "?" : "") }
        return "\(phrase), \(name)" + (asks ? "?" : "")
    }

    /// The line under the greeting, inviting a first message. It changes from day to day.
    public static func invitation(date: Date = Date(), calendar: Calendar = .current) -> String {
        let lines = ["What can I help with?", "What's on your mind?", "What are we working on?", "Where should we start?"]
        return lines[(calendar.ordinality(of: .day, in: .year, for: date) ?? 0) % lines.count]
    }
}
