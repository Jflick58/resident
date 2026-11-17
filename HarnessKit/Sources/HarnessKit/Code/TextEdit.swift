import Foundation

/// Replaces one piece of a file's text, the way the edit tool of a coding agent does.
///
/// The text to find must be in the file exactly once. Small models copy it
/// nearly right: with a space or line break added at an end, or with the
/// indentation of a line changed. Both are forgiven, as long as what is left
/// still points at one place.
public enum TextEdit {
    public enum Outcome: Equatable {
        case changed(String)
        case failed(String)
    }

    public static func replace(_ find: String, with replacement: String, in text: String, path: String) -> Outcome {
        guard !find.isEmpty else { return .failed("`find` is empty. Give the text in \(path) to replace, copied exactly.") }
        var target = find
        var count = occurrences(of: find, in: text)
        if count == 0 {
            let trimmed = find.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != find {
                target = trimmed
                count = occurrences(of: trimmed, in: text)
            }
        }
        if count == 0 {
            switch replaceLines(find, with: replacement, in: text) {
            case .some(.some(let changed)): return changed == text ? .failed(same) : .changed(changed)
            case .some(.none): return .failed(many(path, nil))
            case .none: break
            }
            var message = "That text is not in \(path), so nothing was changed. `find` must be copied exactly from the file."
            if let line = closestLine(to: find, in: text) { message += " The closest line in the file is:\n\(line)" }
            return .failed(message)
        }
        guard count == 1 else { return .failed(many(path, count)) }
        guard target != replacement else { return .failed(same) }
        return .changed(text.replacingOccurrences(of: target, with: replacement))
    }

    private static let same = "`find` and `replace` are the same, so there is nothing to change."

    private static func many(_ path: String, _ count: Int?) -> String {
        "That text is in \(path) \(count.map { "\($0) times" } ?? "more than once"), so nothing was changed. "
            + "Add more of the words around it to `find` so it matches once."
    }

    private static func occurrences(of part: String, in text: String) -> Int {
        text.components(separatedBy: part).count - 1
    }

    /// Matches whole lines with the space at their ends ignored. Nil when no run of lines
    /// matches, `.some(nil)` when more than one does.
    private static func replaceLines(_ find: String, with replacement: String, in text: String) -> String??  {
        func bare(_ line: Substring) -> String { line.trimmingCharacters(in: .whitespaces) }
        let wanted = find.split(separator: "\n", omittingEmptySubsequences: false).map(bare)
            .drop { $0.isEmpty }.reversed().drop { $0.isEmpty }.reversed()
        guard !wanted.isEmpty else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let bared = lines.map(bare)
        guard bared.count >= wanted.count else { return nil }
        let starts = (0...(bared.count - wanted.count)).filter { Array(bared[$0..<($0 + wanted.count)]) == Array(wanted) }
        guard let start = starts.first else { return nil }
        guard starts.count == 1 else { return .some(nil) }
        // A one-line replacement keeps the indentation of the line it replaces.
        var new = replacement.trimmingCharacters(in: .newlines)
        if wanted.count == 1, !new.contains("\n") {
            new = String(lines[start].prefix { $0 == " " || $0 == "\t" }) + new.trimmingCharacters(in: .whitespaces)
        }
        var result = lines.map(String.init)
        result.replaceSubrange(start..<(start + wanted.count), with: [new])
        return .some(result.joined(separator: "\n"))
    }

    /// The line of the file that shares the most words with what the model looked for.
    public static func closestLine(to text: String, in file: String) -> String? {
        func words(_ line: String) -> Set<String> {
            Set(line.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
        }
        let wanted = words(text)
        guard !wanted.isEmpty else { return nil }
        let best = file.split(separator: "\n").map(String.init).max { words($0).intersection(wanted).count < words($1).intersection(wanted).count }
        guard let best, words(best).intersection(wanted).count * 2 >= wanted.count else { return nil }
        return String(best.prefix(400))
    }
}
