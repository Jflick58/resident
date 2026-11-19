import Foundation
import HarnessKit

// A stand-in for GitHub's MCP server: its real tool names, descriptions and
// parameter schemas (github-tools.json, 46 of them, about 32,000 tokens as
// sent), answering from one made-up repository, acme/rocket. It keeps the
// branches and commits a chat makes, so a pull request with nothing in it is
// refused the way GitHub refuses it.

/// What a chat has done to the made-up repository so far.
final class GitHubState: @unchecked Sendable {
    static let shared = GitHubState()
    private let lock = NSLock()
    private var branches: Set<String> = ["main"]
    private var changed: Set<String> = []

    func reset() { lock.withLock { branches = ["main"]; changed = [] } }
    func has(_ branch: String) -> Bool { lock.withLock { branches.contains(branch) } }
    func add(_ branch: String) { lock.withLock { _ = branches.insert(branch) } }
    func commit(to branch: String) { lock.withLock { _ = changed.insert(branch) } }
    func hasCommits(_ branch: String) -> Bool { lock.withLock { changed.contains(branch) } }
    var all: [String] { lock.withLock { branches.sorted() } }
}

struct GitHubTool: Tool {
    var info: ToolSpec
    var recorder: CallRecorder?

    /// The repository's files: path, the id GitHub gives that version of the file, and its text.
    static let files: [(path: String, sha: String, text: String)] = [
        ("README.md", "a41c0de", "# Rokcet\n\nTelemetry and fuel tools for the Rocket project.\n\n## Running\n\n    python -m rocket\n"),
        ("src/gauge.py", "3f2a91c", "OFFSET = 12\n\n\ndef read_fuel_level(sensor):\n    return sensor.raw - OFFSET\n"),
        ("src/telemetry.py", "77b0e12", "def export(rows, writer):\n    for row in rows[:-1]:\n        writer.write(row)\n"),
        (
            "web/styles.css", "9b1d77e",
            "body {\n  margin: 0;\n  background: #ffffff;\n  color: #222222;\n  font-family: Helvetica, Arial, sans-serif;\n}\n\nh1 {\n  font-size: 2rem;\n}\n"
        ),
        ("docs/GUIDE.md", "d0c5a11", guide),
        ("web/index.html", "c0ffee1", "<!doctype html>\n<title>Rocket</title>\n<link rel=\"stylesheet\" href=\"styles.css\">\n<h1>Rocket</h1>\n"),
    ]

    /// A file too long to show a model in one result (about 9,000 characters), with one misspelling near its end.
    static let guide: String = {
        var text = "# Operator guide\n\nHow to run a launch day with the Rocket tools.\n"
        for (number, topic) in ["Fuelling", "Telemetry", "Weather holds", "Range safety", "Countdown", "Recovery"].enumerated() {
            text += "\n## \(number + 1). \(topic)\n\n"
            for step in 1...12 {
                text += "\(step). Check item \(step) of the \(topic.lowercased()) list and log the reading before going on to the next one.\n"
            }
            if topic == "Countdown" { text += "\nThe ground station must recieve a heartbeat every two seconds, or the count stops.\n" }
        }
        return text + "\n## Contacts\n\nRange control: ext. 4410.\n"
    }()

    /// Named and described the way the app presents an MCP tool.
    var spec: ToolSpec {
        MCPTool.modelSpec(
            name: "github_" + info.name, serverName: "GitHub",
            info: MCPToolInfo(name: info.name, description: info.description, inputSchema: info.parameters))
    }

    func call(_ arguments: JSONValue) async -> ToolResult {
        recorder?.record(spec.name, arguments)
        let values = arguments.objectValue ?? [:]
        let allowed = info.parameters["properties"]?.objectValue ?? [:]
        for key in values.keys where allowed[key] == nil { return .error("Unrecognized key: \(key).") }
        for name in info.parameters["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where values[name] == nil {
            return .error("missing required parameter: \(name)")
        }
        func text(_ key: String) -> String {
            if let string = values[key]?.stringValue { return string }
            if let number = values[key]?.intValue { return String(number) }
            if let number = values[key]?.doubleValue { return String(Int(number)) }
            return ""
        }
        // Everything is in the one repository.
        if allowed["repo"] != nil, values["repo"] != nil, text("repo").lowercased() != "rocket" || text("owner").lowercased() != "acme" {
            return .error("Could not resolve to a Repository with the name '\(text("owner"))/\(text("repo"))'.")
        }
        let state = GitHubState.shared
        switch info.name {
        case "get_me": return ToolResult(#"{"login":"sam-rivers","name":"Sam Rivers","public_repos":4}"#)
        case "list_issues", "search_issues":
            if text("state").uppercased() == "CLOSED" { return ToolResult("No issues.") }
            return ToolResult(
                """
                #12  open  2026-08-02  Fuel gauge reads negative after refuelling
                #31  open  2026-10-19  Telemetry export drops the last row
                #40  open  2026-11-09  Docs: launch checklist is out of date
                3 open issues.
                """)
        case "issue_read":
            switch text("issue_number") {
            case "12": return ToolResult("#12 Fuel gauge reads negative after refuelling. 2 comments. Latest: \"Reproduced on v2.3.\"")
            case "31": return ToolResult("#31 Telemetry export drops the last row. 1 comment. Latest: \"Off-by-one in the writer loop.\"")
            case "40": return ToolResult("#40 Docs: launch checklist is out of date. No comments.")
            default: return .error("Issue #\(text("issue_number")) was not found.")
            }
        case "add_issue_comment":
            guard !text("body").isEmpty else { return .error("body is required unless reaction is provided.") }
            return ToolResult("Comment posted on #\(text("issue_number")).")
        case "issue_write":
            if text("method") == "create" {
                guard !text("title").isEmpty else { return .error("title is required to create an issue.") }
                return ToolResult("Opened #41: \(text("title")).")
            }
            return ToolResult("Updated #\(text("issue_number")).")
        case "list_pull_requests", "search_pull_requests":
            return ToolResult("#38  dana  Fix telemetry export  (approved)\n#39  li  Bump dependencies  (review needed)")
        case "pull_request_read": return ToolResult("#38 Fix telemetry export by dana. 2 files changed. Approved by li.")
        case "search_code":
            let query = text("query").lowercased()
            if ["background", "color", "colour", "css", "style"].contains(where: query.contains) {
                return ToolResult("acme/rocket  web/styles.css:3    background: #ffffff;")
            }
            if ["fuel", "gauge", "offset"].contains(where: query.contains) {
                return ToolResult("acme/rocket  src/gauge.py:4  def read_fuel_level(sensor):")
            }
            if ["telemetry", "export"].contains(where: query.contains) { return ToolResult("acme/rocket  src/telemetry.py:1  def export(rows, writer):") }
            return ToolResult("No results.")
        case "get_file_contents":
            let path = text("path").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let file = Self.files.first(where: { $0.path == path }) {
                return ToolResult("successfully downloaded text file (SHA: \(file.sha))\n\(file.text)")
            }
            // A folder: what is directly inside it.
            let inside = Self.files.compactMap { file -> String? in
                guard path.isEmpty || file.path.hasPrefix(path + "/") else { return nil }
                let rest = path.isEmpty ? file.path : String(file.path.dropFirst(path.count + 1))
                return rest.contains("/") ? String(rest.prefix { $0 != "/" }) + "/" : rest
            }
            guard !inside.isEmpty else { return .error("failed to get file contents: path \(path) was not found.") }
            return ToolResult(Array(Set(inside)).sorted().joined(separator: "\n"))
        case "list_branches": return ToolResult(state.all.joined(separator: "\n"))
        case "create_branch":
            guard !state.has(text("branch")) else { return .error("Reference already exists: \(text("branch")).") }
            state.add(text("branch"))
            return ToolResult("Created branch \(text("branch")) from \(text("from_branch").isEmpty ? "main" : text("from_branch")).")
        case "create_or_update_file":
            guard state.has(text("branch")) else { return .error("Branch \(text("branch")) not found.") }
            let path = text("path").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let file = Self.files.first(where: { $0.path == path }), text("sha") != file.sha {
                return .error(
                    text("sha").isEmpty
                        ? "\"sha\" wasn't supplied. It is required to update a file that exists: it is in the result of get_file_contents."
                        : "\(path) does not match \(text("sha")).")
            }
            state.commit(to: text("branch"))
            return ToolResult("Committed \(path) to \(text("branch")).")
        case "push_files":
            guard state.has(text("branch")) else { return .error("Branch \(text("branch")) not found.") }
            state.commit(to: text("branch"))
            return ToolResult("Pushed to \(text("branch")).")
        case "create_pull_request":
            let base = text("base")
            guard state.has(text("head")) else { return .error("failed to create pull request: Validation Failed PullRequest.head (invalid)") }
            guard state.hasCommits(text("head")), text("head") != base else {
                return .error("failed to create pull request: Validation Failed PullRequest (custom): No commits between \(base) and \(text("head"))")
            }
            return ToolResult("Created pull request #42: https://github.com/acme/rocket/pull/42")
        case "merge_pull_request": return ToolResult("Merged.")
        default: return ToolResult("No results.")
        }
    }
}

func loadGitHubTools(recorder: CallRecorder) -> [GitHubTool] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("github-tools.json")
    guard let data = try? Data(contentsOf: url), let specs = try? JSONDecoder().decode([ToolSpec].self, from: data) else {
        print("Could not read \(url.path)")
        exit(2)
    }
    return specs.map { GitHubTool(info: $0, recorder: recorder) }
}

/// The same made-up repository as a place to clone from and open pull requests on, for the code
/// tools. A pull request's files go in the record whole, so a case can check that a change left
/// the rest of a file alone.
struct RecordingHost: RepositoryHost {
    var base: FixedRepositoryHost
    var recorder: CallRecorder

    func reset() { base.reset() }

    func download(owner: String, repo: String, into directory: URL) async throws -> RepositoryVersion {
        try await base.download(owner: owner, repo: repo, into: directory)
    }

    func openPullRequest(_ draft: PullRequestDraft) async throws -> OpenedPullRequest {
        recorder.record(
            "pull_request_content",
            ["branch": .string(draft.branch), "files": .object(Dictionary(uniqueKeysWithValues: draft.files.map { ($0.path, JSONValue.string($0.text)) }))])
        return try await base.openPullRequest(draft)
    }
}

/// A host whose one repository is a folder on this Mac: what a chat on a phone cloned from GitHub is
/// copied from disk here. A pull request is printed, not sent anywhere.
struct FolderRepositoryHost: RepositoryHost {
    var owner: String
    var repo: String
    var folder: URL

    func download(owner: String, repo: String, into directory: URL) async throws -> RepositoryVersion {
        guard owner.lowercased() == self.owner.lowercased(), repo.lowercased() == self.repo.lowercased() else {
            throw RepositoryError("GitHub has no such repository, or this account cannot see it.")
        }
        for item in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where item.lastPathComponent != ".git" {
            try FileManager.default.copyItem(at: item, to: directory.appendingPathComponent(item.lastPathComponent))
        }
        return RepositoryVersion(branch: "main", commit: "c0ffee0")
    }

    func openPullRequest(_ draft: PullRequestDraft) async throws -> OpenedPullRequest {
        print("  PULL REQUEST \(draft.title) | \(draft.body.replacingOccurrences(of: "\n", with: " / "))")
        for file in draft.files {
            let before = (try? String(contentsOf: folder.appendingPathComponent(file.path), encoding: .utf8)) ?? ""
            let was = before.split(separator: "\n", omittingEmptySubsequences: false)
            let now = file.text.split(separator: "\n", omittingEmptySubsequences: false)
            print("  CHANGED \(file.path)")
            for line in was where !now.contains(line) { print("    - \(line)") }
            for line in now where !was.contains(line) { print("    + \(line)") }
        }
        return OpenedPullRequest(number: 42, url: "https://github.com/\(owner)/\(repo)/pull/42", branch: draft.branch, commit: "c0ffee42")
    }
}
