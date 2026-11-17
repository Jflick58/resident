import Foundation

/// The tools for working on a repository's code: the few a coding agent has
/// (list, search, read, edit, write), with a clone before them and a pull
/// request after. See `Workspace` for why.
public struct RepoTool: Tool {
    public enum Kind: String, CaseIterable, Sendable {
        case clone, list = "list_files", search, read = "read_file", edit = "edit_file", write = "write_file"
        case pullRequest = "open_pull_request"
    }

    public static let prefix = "repo"
    public var kind: Kind
    var workspace: Workspace
    /// Called with each call's name and arguments, for the test bed's record.
    var onCall: (@Sendable (String, JSONValue) -> Void)?

    public static func name(_ kind: Kind) -> String { "\(prefix)_\(kind.rawValue)" }

    /// The connector these tools make up.
    public static func group(workspace: Workspace, onCall: (@Sendable (String, JSONValue) -> Void)? = nil) -> ToolGroup {
        ToolGroup(
            name: prefix, title: "Code",
            summary: "Work on the code of a GitHub repository: clone it, list, search, read and edit its files, and open a pull request",
            tools: Kind.allCases.map { RepoTool(kind: $0, workspace: workspace, onCall: onCall) })
    }

    public var spec: ToolSpec {
        func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
            ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })]
        }
        func string(_ description: String) -> JSONValue { ["type": "string", "description": .string(description)] }
        let path = string("Path of the file from the top of the repository, e.g. src/main.py")
        switch kind {
        case .clone:
            return ToolSpec(
                name: Self.name(kind),
                description: "[Code] Get a copy of a GitHub repository to work on. Do this first. Returns its files.",
                parameters: object(["repository": string("The repository as owner/name")], required: ["repository"]))
        case .list:
            return ToolSpec(
                name: Self.name(kind), description: "[Code] List the files in the cloned repository, or in one of its folders.",
                parameters: object(["path": string("A folder. Leave out for the top of the repository.")], required: []))
        case .search:
            return ToolSpec(
                name: Self.name(kind),
                description: "[Code] Search the cloned repository's files for text, like grep. Returns each match as path:line: text.",
                parameters: object(
                    [
                        "query": string("Text or a regular expression to look for. Case does not matter."),
                        "path": string("A folder or file to search in. Leave out to search everything."),
                    ], required: ["query"]))
        case .read:
            return ToolSpec(
                name: Self.name(kind), description: "[Code] Read a file of the cloned repository. A long file comes a part at a time.",
                parameters: object(
                    ["path": path, "start_line": ["type": "integer", "description": "Line to start from. Leave out for the start of the file."]],
                    required: ["path"]))
        case .edit:
            return ToolSpec(
                name: Self.name(kind),
                description: "[Code] Change part of a file in the cloned repository. Give the exact text to find and the text to put in its place. The rest of the file stays as it is.",
                parameters: object(
                    [
                        "path": path, "find": string("Text in the file to replace, copied exactly. It must be in the file once."),
                        "replace": string("Text to put in its place"),
                    ], required: ["path", "find", "replace"]))
        case .write:
            return ToolSpec(
                name: Self.name(kind),
                description: "[Code] Make a new file in the cloned repository with this content. To change a file that exists, use \(Self.name(.edit)).",
                parameters: object(["path": path, "content": string("The whole content of the file")], required: ["path", "content"]))
        case .pullRequest:
            return ToolSpec(
                name: Self.name(kind),
                description: "[Code] Open a pull request with every change made to the cloned repository. Makes the branch and the commit itself. Does not merge.",
                parameters: object(
                    ["title": string("What changed, in a few words"), "body": string("A sentence or two on what changed and why")],
                    required: ["title"]))
        }
    }

    public func summary(for arguments: JSONValue) -> String { Self.activity(kind, arguments) }

    /// A line for the transcript for a call to one of these tools, or nil when the name is not one of them.
    public static func activity(forTool name: String, arguments: JSONValue) -> String? {
        guard name.hasPrefix(prefix + "_"), let kind = Kind(rawValue: String(name.dropFirst(prefix.count + 1))) else { return nil }
        return activity(kind, arguments)
    }

    private static func activity(_ kind: Kind, _ arguments: JSONValue) -> String {
        let path = arguments["path"]?.stringValue ?? ""
        switch kind {
        case .clone: return "Cloned \(arguments["repository"]?.stringValue ?? "a repository")"
        case .list: return "Listed \(path.isEmpty ? "the files" : path)"
        case .search: return "Searched the code for “\(arguments["query"]?.stringValue ?? "")”"
        case .read: return "Read \(path.isEmpty ? "a file" : path)"
        case .edit: return "Edited \(path.isEmpty ? "a file" : path)"
        case .write: return "Wrote \(path.isEmpty ? "a file" : path)"
        case .pullRequest: return "Opened a pull request"
        }
    }

    public func call(_ arguments: JSONValue) async -> ToolResult {
        onCall?(spec.name, arguments)
        func text(_ keys: String...) -> String {
            for key in keys { if let value = arguments[key]?.stringValue, !value.isEmpty { return value } }
            return ""
        }
        switch kind {
        case .clone:
            // Models also give the two halves apart, as GitHub's own tools take them.
            let whole = text("repository", "repo", "url", "name")
            let owner = text("owner")
            return await workspace.clone(owner.isEmpty || whole.contains("/") ? whole : "\(owner)/\(whole)")
        case .list: return await workspace.list(text("path", "folder", "directory"))
        case .search: return await workspace.search(text("query", "pattern", "text"), in: text("path", "folder"))
        case .read:
            let start = arguments["start_line"]?.intValue ?? arguments["start_line"]?.doubleValue.map(Int.init)
                ?? Int(arguments["start_line"]?.stringValue ?? "") ?? 1
            return await workspace.read(text("path", "file"), from: start)
        case .edit:
            return await workspace.edit(text("path", "file"), find: text("find", "old_string", "old_text", "search"),
                replace: arguments["replace"]?.stringValue ?? text("new_string", "new_text"))
        case .write: return await workspace.write(text("path", "file"), content: text("content", "text"))
        case .pullRequest: return await workspace.openPullRequest(title: text("title"), body: text("body", "description"))
        }
    }
}
