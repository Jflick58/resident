import Foundation

/// Changes one piece of text in a file of a GitHub repository.
///
/// GitHub's own tool for saving a file takes the whole file. A small model cannot
/// write a long file back exactly: a 10,000 character README is some 2,600 tokens,
/// more than one reply holds, and one slip anywhere in it damages the file. This
/// tool takes the text to find and what to put in its place, like the edit tool
/// of a coding agent. It reads the file, makes the change and saves it, using the
/// connector's own two tools, so the model only writes the part that changes.
public struct FileEditTool: Tool {
    static let readSuffix = "get_file_contents"
    static let writeSuffix = "create_or_update_file"
    static let suffix = "edit_file"

    var name: String
    var title: String
    var read: any Tool
    var write: any Tool

    /// These tools with an edit tool added, when they include the two it is built from.
    public static func adding(to tools: [any Tool], title: String) -> [any Tool] {
        guard let read = tools.first(where: { $0.spec.name.hasSuffix(readSuffix) }),
            let write = tools.first(where: { $0.spec.name.hasSuffix(writeSuffix) })
        else { return tools }
        let name = String(read.spec.name.dropLast(readSuffix.count)) + suffix
        guard !tools.contains(where: { $0.spec.name == name }) else { return tools }
        return tools + [FileEditTool(name: name, title: title, read: read, write: write)]
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "[\(title)] Change part of a file that exists and commit it to a branch. Give the exact text to find and the text to "
                + "put in its place; the rest of the file stays as it is. Use this, not \(write.spec.name), to edit a file.",
            parameters: [
                "type": "object",
                "properties": [
                    "owner": ["type": "string", "description": "Repository owner"],
                    "repo": ["type": "string", "description": "Repository name"],
                    "path": ["type": "string", "description": "Path of the file"],
                    "branch": ["type": "string", "description": "Branch to commit to. It must exist."],
                    "find": ["type": "string", "description": "Text in the file to replace, copied exactly. It must be in the file once."],
                    "replace": ["type": "string", "description": "Text to put in its place"],
                    "message": ["type": "string", "description": "Commit message"],
                ],
                "required": ["owner", "repo", "path", "branch", "find", "replace", "message"],
            ])
    }

    public func summary(for arguments: JSONValue) -> String { "\(title): edit \(arguments["path"]?.stringValue ?? "a file")" }

    public func call(_ arguments: JSONValue) async -> ToolResult {
        func text(_ key: String) -> String { arguments[key]?.stringValue ?? "" }
        for key in ["owner", "repo", "path", "branch", "find"] where text(key).isEmpty {
            return .error("Missing required argument: \(key).")
        }
        let path = text("path")
        let branch = text("branch").replacingOccurrences(of: "refs/heads/", with: "")
        let found = await read.call(["owner": .string(text("owner")), "repo": .string(text("repo")), "path": .string(path), "ref": .string("refs/heads/" + branch)])
        guard !found.isError else {
            return .error("Could not read \(path) on branch \(branch): \(found.text)\nIf the branch does not exist yet, make it first.")
        }
        guard let file = Self.file(in: found.text) else { return .error("\(path) is not a text file that can be edited.") }

        let find = text("find")
        var count = file.text.components(separatedBy: find).count - 1
        var target = find
        if count == 0 {
            // Models often add or drop the space or line break at either end.
            let trimmed = find.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                target = trimmed
                count = file.text.components(separatedBy: trimmed).count - 1
            }
        }
        guard count > 0 else {
            var message = "That text is not in \(path), so nothing was changed. `find` must be copied exactly from the file."
            if let line = Self.closestLine(to: find, in: file.text) { message += " The closest line in the file is:\n\(line)" }
            return .error(message)
        }
        guard count == 1 else {
            return .error("That text is in \(path) \(count) times, so nothing was changed. Add more of the words around it to `find` so it matches once.")
        }
        guard target != text("replace") else { return .error("`find` and `replace` are the same, so there is nothing to change.") }

        let changed = file.text.replacingOccurrences(of: target, with: text("replace"))
        let saved = await write.call([
            "owner": .string(text("owner")), "repo": .string(text("repo")), "path": .string(path), "branch": .string(branch),
            "content": .string(changed), "message": .string(text("message").isEmpty ? "Update \(path)" : text("message")),
            "sha": .string(file.sha),
        ])
        guard !saved.isError else { return .error("Could not save \(path): \(saved.text)") }
        return ToolResult("Changed \(path) on branch \(branch) and committed it. The rest of the file is as it was.")
    }

    /// The file's text and SHA from what GitHub's read tool returns: a line naming the SHA, then the file.
    static func file(in result: String) -> (sha: String, text: String)? {
        guard let end = result.firstIndex(of: "\n") else { return nil }
        let first = String(result[..<end])
        guard let match = first.range(of: #"SHA: ([0-9a-f]{7,64})"#, options: .regularExpression) else { return nil }
        return (String(first[match].dropFirst(5)), String(result[result.index(after: end)...]))
    }

    /// The line of the file that shares the most words with what the model looked for.
    static func closestLine(to text: String, in file: String) -> String? {
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
