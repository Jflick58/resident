import Foundation

/// The tools for working on files: the few a coding agent has (list, search,
/// read, edit, write), under the names a coding agent gives them. They work on
/// any files in the folder and know nothing of where those came from. See `Workspace`.
public struct FileTool: Tool {
    public enum Kind: String, CaseIterable, Sendable {
        case list = "list_files", search = "search_files", read = "read_file", edit = "edit_file", write = "write_file"
    }

    public var kind: Kind
    var workspace: Workspace
    /// How files are got into the folder, said when it is empty.
    var source: String?
    /// Called with each call's name and arguments, for the test bed's record.
    var onCall: (@Sendable (String, JSONValue) -> Void)?

    public static func name(_ kind: Kind) -> String { kind.rawValue }

    /// Steps a turn gets on top of the usual ones while it works on files. Finding the place for a
    /// change in a real project is most of the work: asked to change a colour in an app of 944
    /// files, a model used all 14 of a connector's steps reading and searching, twice, and each
    /// step was cheap (a second or two on a phone).
    public static let steps = 18

    /// The connector these tools make up. With a copy of a repository, the two tools that are
    /// GitHub's come at the ends, in the order they are used: clone first, pull request last.
    /// `connector` is the prefix of the GitHub connector's own tools, whose names a model mixes with these.
    public static func group(
        workspace: Workspace, repository: RepositoryCopy? = nil, connector: String = "github",
        onCall: (@Sendable (String, JSONValue) -> Void)? = nil
    ) -> ToolGroup {
        let files = Kind.allCases.map {
            FileTool(kind: $0, workspace: workspace, source: repository == nil ? nil : RepositoryCopy.cloneFirst, onCall: onCall)
        }
        var summary = "Work on files in a folder on this device: list, search, read, edit and write them"
        var tools: [any Tool] = files
        if let repository {
            summary += ". With GitHub: clone a repository into the folder, and open a pull request with the changes"
            tools = [RepositoryTool(kind: .clone, repository: repository, onCall: onCall)] + files
                + [RepositoryTool(kind: .pullRequest, repository: repository, onCall: onCall)]
        }
        var group = ToolGroup(name: Connector.files.rawValue, title: Connector.files.title, summary: summary, tools: tools)
        group.extraSteps = steps
        if repository != nil { group.redirects = RepositoryTool.redirects(connector: connector) }
        return group
    }

    public var spec: ToolSpec {
        func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
            ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })]
        }
        func string(_ description: String) -> JSONValue { ["type": "string", "description": .string(description)] }
        let path = string("Path of the file from the top of the files folder, e.g. notes/todo.md")
        switch kind {
        case .list:
            return ToolSpec(
                name: Self.name(kind), description: "[Files] List the files in the files folder, or in one of its folders.",
                parameters: object(["path": string("A folder. Leave out for the top.")], required: []))
        case .search:
            return ToolSpec(
                name: Self.name(kind),
                description: "[Files] Search the files for text, like grep. Returns each match as path:line: text.",
                parameters: object(
                    [
                        "query": string("Text or a regular expression to look for. Case does not matter."),
                        "path": string("A folder or file to search in. Leave out to search everything."),
                    ], required: ["query"]))
        case .read:
            return ToolSpec(
                name: Self.name(kind), description: "[Files] Read a file in the files folder. A long file comes a part at a time.",
                parameters: object(
                    ["path": path, "start_line": ["type": "integer", "description": "Line to start from. Leave out for the start of the file."]],
                    required: ["path"]))
        case .edit:
            return ToolSpec(
                name: Self.name(kind),
                description: "[Files] Change part of a file. Give the exact text to find and the text to put in its place. The rest of the file stays as it is.",
                parameters: object(
                    [
                        "path": path, "find": string("Text in the file to replace, copied exactly. It must be in the file once."),
                        "replace": string("Text to put in its place"),
                    ], required: ["path", "find", "replace"]))
        case .write:
            return ToolSpec(
                name: Self.name(kind),
                description: "[Files] Make a new file with this content. To change a file that exists, use \(Self.name(.edit)).",
                parameters: object(["path": path, "content": string("The whole content of the file")], required: ["path", "content"]))
        }
    }

    public func summary(for arguments: JSONValue) -> String { Self.activity(kind, arguments) }

    /// What these tools were called while they belonged to the code connector, for chats from then.
    private static let earlier: [String: Kind] = [
        "repo_list_files": .list, "repo_search": .search, "repo_read_file": .read, "repo_edit_file": .edit, "repo_write_file": .write,
    ]

    /// A line for the transcript for a call to one of these tools, or nil when the name is not one of them.
    public static func activity(forTool name: String, arguments: JSONValue) -> String? {
        (Kind(rawValue: name) ?? earlier[name]).map { activity($0, arguments) }
    }

    private static func activity(_ kind: Kind, _ arguments: JSONValue) -> String {
        let path = arguments["path"]?.stringValue ?? ""
        switch kind {
        case .list: return "Listed \(path.isEmpty ? "the files" : path)"
        case .search: return "Searched the files for “\(arguments["query"]?.stringValue ?? "")”"
        case .read: return "Read \(path.isEmpty ? "a file" : path)"
        case .edit: return "Edited \(path.isEmpty ? "a file" : path)"
        case .write: return "Wrote \(path.isEmpty ? "a file" : path)"
        }
    }

    public func call(_ arguments: JSONValue) async -> ToolResult {
        onCall?(spec.name, arguments)
        // The names other coding agents give the same arguments are taken too.
        func text(_ keys: String...) -> String {
            for key in keys { if let value = arguments[key]?.stringValue, !value.isEmpty { return value } }
            return ""
        }
        switch kind {
        case .list: return await workspace.counted(await workspace.list(text("path", "folder", "directory"), source: source))
        case .search:
            return await workspace.counted(await workspace.search(text("query", "pattern", "text"), in: text("path", "folder"), source: source))
        case .read:
            let start = arguments["start_line"]?.intValue ?? arguments["start_line"]?.doubleValue.map(Int.init)
                ?? Int(arguments["start_line"]?.stringValue ?? "") ?? 1
            return await workspace.counted(await workspace.read(text("path", "file"), from: start, source: source))
        case .edit:
            return await workspace.edit(
                text("path", "file"), find: text("find", "old_string", "old_text", "search"),
                replace: arguments["replace"]?.stringValue ?? text("new_string", "new_text"), source: source)
        case .write: return await workspace.write(text("path", "file"), content: text("content", "text"))
        }
    }
}
