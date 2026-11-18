import Foundation

/// A copy of one GitHub repository in the files folder, and the pull requests
/// made from it. These are the two ends of working on a repository's code and
/// the only parts that are GitHub's: getting the files, and publishing what
/// was changed. Between them the model uses the file tools, as on any files.
///
/// Small models tuned for code have seen a coding agent's loop endlessly. They
/// have not seen GitHub's API. Given GitHub's own tools, a coder model on a
/// phone spent every step it had looking for one file: its search ran over all
/// of GitHub because the repository belongs inside the query text, an optional
/// `fields` argument refused five guesses, and it never listed a folder. Here
/// the branch, the commit and the upload are the harness's business. The model
/// changes files and says what the pull request is called.
///
/// One repository is kept at a time, in a folder named after it. Cloning
/// another replaces it.
public actor RepositoryCopy {
    struct State: Codable {
        var owner: String
        var repo: String
        /// The folder of the workspace that holds it.
        var folder: String
        var version: RepositoryVersion
    }

    /// Changes older than this are dropped when the repository is cloned again:
    /// they belong to a chat that was given up.
    static let keepChangesFor: TimeInterval = 30 * 60
    /// Said by the file tools when the files folder is empty.
    public static let cloneFirst = "To work on a GitHub repository, call \(RepositoryTool.name(.clone)) with it first, as owner/name."
    /// Said by the file tools after a file of the repository is changed.
    static let afterChange = "When every change is made, call \(RepositoryTool.name(.pullRequest))."
    private static let none = "No repository is cloned yet. Call \(RepositoryTool.name(.clone)) with the repository first, as owner/name."

    private let workspace: Workspace
    private let host: any RepositoryHost
    private var state: State?

    public init(workspace: Workspace, host: any RepositoryHost) {
        self.workspace = workspace
        self.host = host
        state = (try? Data(contentsOf: Self.record(in: workspace.directory))).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
    }

    private static func record(in directory: URL) -> URL { directory.appendingPathComponent("repository.json") }

    private func save() {
        try? FileManager.default.createDirectory(at: workspace.directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: Self.record(in: workspace.directory))
    }

    /// Forgets the repository. Its files go when the workspace is reset.
    public func reset() {
        try? FileManager.default.removeItem(at: Self.record(in: workspace.directory))
        state = nil
    }

    /// The repository that is cloned, when its folder is still the workspace's project folder.
    private func current() async -> State? {
        guard let state, await workspace.project?.folder == state.folder else { return nil }
        return state
    }

    /// `owner/name` from that, or from a GitHub address.
    static func repository(in text: String) -> (owner: String, repo: String)? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "www.", "github.com/", "git@github.com:"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        let parts = text.split(separator: "/").map(String.init)
        func isName(_ part: String) -> Bool {
            part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." } && part.contains { $0 != "." }
        }
        guard parts.count >= 2, isName(parts[0]), isName(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }

    public func clone(_ text: String) async -> ToolResult {
        guard let (owner, repo) = Self.repository(in: text) else {
            return .error("Give the repository as owner/name, for example octocat/hello-world.")
        }
        if let state = await current(), state.owner.lowercased() == owner.lowercased(), state.repo.lowercased() == repo.lowercased() {
            let changes = await workspace.changes(under: state.folder)
            if let latest = changes.map(\.at).max(), Date().timeIntervalSince(latest) < Self.keepChangesFor {
                return ToolResult(
                    "\(state.owner)/\(state.repo) is already cloned in \(state.folder)/, with your changes to \(changes.map(\.path).joined(separator: ", ")) kept.\n"
                        + (await workspace.listing(state.folder)))
            }
        }
        let fresh = workspace.directory.appendingPathComponent("incoming", isDirectory: true)
        try? FileManager.default.removeItem(at: fresh)
        let cloned: State
        do {
            try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
            let version = try await host.download(owner: owner, repo: repo, into: fresh)
            let folder = try await workspace.adopt(fresh, named: repo, afterChange: Self.afterChange)
            cloned = State(owner: owner, repo: repo, folder: folder, version: version)
            state = cloned
            save()
        } catch {
            try? FileManager.default.removeItem(at: fresh)
            return .error("Could not clone \(owner)/\(repo): \(error.localizedDescription)")
        }
        return ToolResult(
            "Cloned \(owner)/\(repo) into \(cloned.folder)/, branch \(cloned.version.branch), \(await workspace.count(under: cloned.folder)) files.\n"
                + (await workspace.listing(cloned.folder)))
    }

    public func openPullRequest(title: String, body: String) async -> ToolResult {
        guard let current = await current() else { return .error(Self.none) }
        let changed = await workspace.changes(under: current.folder).map(\.path)
        guard !changed.isEmpty else {
            return .error(
                "No file in \(current.folder)/ has been changed yet, so there is nothing to put in a pull request. Change a file there with \(FileTool.name(.edit)) first.")
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .error("Give a title that says what changed.") }
        // GitHub knows the files by their paths in the repository, without the folder it is kept in here.
        let files = await workspace.texts(of: changed).map { (path: String($0.path.dropFirst(current.folder.count + 1)), text: $0.text) }
        let slug = Skill.slug(title).split(separator: "-").prefix(6).joined(separator: "-")
        let draft = PullRequestDraft(
            owner: current.owner, repo: current.repo, base: current.version.branch, commit: current.version.commit,
            branch: slug.isEmpty ? "change" : String(slug.prefix(48)), title: title, body: body, files: files)
        do {
            let opened = try await host.openPullRequest(draft)
            state?.version.commit = opened.commit
            save()
            await workspace.forgetChanges(under: current.folder)
            return ToolResult(
                "Opened pull request #\(opened.number): \(opened.url)\nIt changes \(files.map(\.path).joined(separator: ", ")) on a new branch, \(opened.branch). It is not merged. Give the user the link.")
        } catch {
            return .error("The pull request was not opened: \(error.localizedDescription) Your changes are kept.")
        }
    }
}

/// The two tools that are GitHub's: clone a repository into the files folder, and open a pull
/// request with what was changed in it. They sit with the file tools, which do everything between,
/// and are labelled as theirs: beside GitHub's own `github_create_pull_request`, a tool marked
/// GitHub too was taken for its twin.
public struct RepositoryTool: Tool {
    /// Named as they were when all seven tools came with GitHub, so chats and skills from then still
    /// name them. A plainer name did no better: as `open_pull_request` the second was passed over
    /// after an edit for `github_open_pull_request`, which does not exist, or for GitHub's own
    /// `github_create_pull_request` (LFM3, 7 of 11 pull request tasks). What stopped that was
    /// leaving GitHub's own out: see `replaced`.
    public enum Kind: String, CaseIterable, Sendable {
        case clone = "repo_clone", pullRequest = "repo_open_pull_request"
    }

    public var kind: Kind
    var repository: RepositoryCopy
    /// Called with each call's name and arguments, for the test bed's record.
    var onCall: (@Sendable (String, JSONValue) -> Void)?

    public static func name(_ kind: Kind) -> String { kind.rawValue }
    public static var names: [String] { Kind.allCases.map(\.rawValue) }

    /// The tools of GitHub's own connector that change a repository's code the long way round: a
    /// branch, then each file written back whole, then a pull request. Beside these tools they are
    /// a second way to do one job, and the one that fails: a pull request made with them cannot
    /// see what was changed here, and is empty. With both in front of it, LFM3 left for them after
    /// its edit in 6 pull request tasks of 23, and 2 of those never came back; without them it
    /// finished 23 of 23. So GitHub's connector goes without them while these tools are there.
    /// Named by what follows the connector's prefix.
    static let replaced: Set<String> = ["create_pull_request", "create_branch", "create_or_update_file", "push_files", "delete_file", "edit_file"]

    /// True when `tool` is one of those, in a connector whose tools start with `prefix`.
    public static func replaces(_ tool: String, connector prefix: String) -> Bool {
        tool.hasPrefix(prefix + "_") && replaced.contains(String(tool.dropFirst(prefix.count + 1)))
    }

    /// What to say when one of those is called all the same, or a name a model makes up in their
    /// place: after an edit, a model that has read `repo_open_pull_request` calls
    /// `github_open_pull_request`, because a pull request is GitHub's.
    public static func redirects(connector prefix: String) -> [String: ToolGroup.Redirect] {
        let open = ToolGroup.Redirect(
            tool: name(.pullRequest), say: "Use \(name(.pullRequest)), which opens the pull request with the changes made here.")
        let branch = ToolGroup.Redirect(
            tool: name(.pullRequest), say: "No branch is needed: \(name(.pullRequest)) makes the branch and the commit itself.")
        let clone = ToolGroup.Redirect(tool: name(.clone), say: "Use \(name(.clone)), which copies the repository into the files folder.")
        let edit = ToolGroup.Redirect(
            tool: FileTool.name(.edit),
            say: "Use \(FileTool.name(.edit)) on the copy in the files folder. \(name(.pullRequest)) sends the change to GitHub.")
        let write = ToolGroup.Redirect(
            tool: FileTool.name(.write),
            say: "Use \(FileTool.name(.write)) for a new file in the copy in the files folder. \(name(.pullRequest)) sends it to GitHub.")
        var redirects: [String: ToolGroup.Redirect] = [:]
        for wrong in ["open_pull_request", "create_pull_request", "\(prefix)_open_pull_request", "\(prefix)_create_pull_request", "\(prefix)_push_files"] {
            redirects[wrong] = open
        }
        redirects["\(prefix)_create_branch"] = branch
        for wrong in ["clone_repository", "git_clone", "\(prefix)_clone", "\(prefix)_clone_repository", "\(prefix)_repo_clone"] { redirects[wrong] = clone }
        for wrong in ["\(prefix)_edit_file", "\(prefix)_create_or_update_file"] { redirects[wrong] = edit }
        redirects["\(prefix)_write_file"] = write
        return redirects
    }

    public var spec: ToolSpec {
        func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
            ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })]
        }
        func string(_ description: String) -> JSONValue { ["type": "string", "description": .string(description)] }
        switch kind {
        case .clone:
            return ToolSpec(
                name: Self.name(kind),
                description: "[Files] Copy a GitHub repository into the files folder, to work on its files. Do this first. Returns its files.",
                parameters: object(["repository": string("The repository as owner/name")], required: ["repository"]))
        case .pullRequest:
            return ToolSpec(
                name: Self.name(kind),
                description: "[Files] Open a pull request on GitHub with every change made to the cloned repository's files. Makes the branch and the commit itself. Does not merge.",
                parameters: object(
                    ["title": string("What changed, in a few words"), "body": string("A sentence or two on what changed and why")],
                    required: ["title"]))
        }
    }

    public func summary(for arguments: JSONValue) -> String { Self.activity(kind, arguments) }

    /// A line for the transcript for a call to one of these tools, or nil when the name is not one of them.
    public static func activity(forTool name: String, arguments: JSONValue) -> String? {
        Kind(rawValue: name).map { activity($0, arguments) }
    }

    private static func activity(_ kind: Kind, _ arguments: JSONValue) -> String {
        switch kind {
        case .clone: return "Cloned \(arguments["repository"]?.stringValue ?? "a repository")"
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
            return await repository.clone(owner.isEmpty || whole.contains("/") ? whole : "\(owner)/\(whole)")
        case .pullRequest: return await repository.openPullRequest(title: text("title"), body: text("body", "description"))
        }
    }
}
