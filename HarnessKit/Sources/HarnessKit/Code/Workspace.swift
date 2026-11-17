import Foundation

/// A copy of one repository on this device, for a model to work on the way a
/// coding agent works on a folder: list it, search it, read a file, edit it.
///
/// Small models tuned for code have seen that loop endlessly. They have not
/// seen GitHub's API. Given GitHub's own tools, a coder model on a phone spent
/// every step it had looking for one file: its search ran over all of GitHub
/// because the repository belongs inside the query text, an optional `fields`
/// argument refused five guesses, and it never listed a folder. Here the
/// branch, the commit and the upload are the harness's business. The model
/// changes files and says what the pull request is called.
///
/// One repository is kept at a time. Cloning another replaces it.
public actor Workspace {
    struct State: Codable {
        var owner: String
        var repo: String
        var version: RepositoryVersion
        /// Paths changed since the download or the last pull request.
        var changed: [String] = []
        var changedAt: Date?
    }

    /// Changes older than this are dropped when the repository is cloned again:
    /// they belong to a chat that was given up.
    static let keepChangesFor: TimeInterval = 30 * 60
    static let readLines = 200
    static let readCharacters = 4500
    static let searchMatches = 30
    static let searchMatchesPerFile = 4
    static let listEntries = 150
    /// Folders of other people's code, searched after the repository's own.
    static let vendored = ["vendor/", "node_modules/", "third_party/", "pods/", ".build/", "deriveddata/", "dist/"]

    private let root: URL
    private let host: any RepositoryHost
    private var state: State?

    public init(directory: URL, host: any RepositoryHost) {
        root = directory
        self.host = host
        state = (try? Data(contentsOf: directory.appendingPathComponent("state.json"))).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
    }

    private var files: URL { root.appendingPathComponent("files", isDirectory: true) }

    private func save() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: root.appendingPathComponent("state.json"))
    }

    /// Forgets the repository and deletes its files.
    public func reset() {
        try? FileManager.default.removeItem(at: root)
        state = nil
    }

    private static let none = "No repository is cloned yet. Call repo_clone with the repository first, as owner/name."

    // MARK: Paths

    /// `owner/name` from that, or from a GitHub address.
    static func repository(in text: String) -> (owner: String, repo: String)? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "www.", "github.com/", "git@github.com:"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        let parts = text.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }),
            parts[1].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." })
        else { return nil }
        return (parts[0], parts[1])
    }

    /// A path as the model gave it, made relative to the repository. Nil when it points outside.
    static func clean(_ path: String) -> String? {
        var parts: [Substring] = []
        for part in path.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/") where part != "." {
            if part == ".." { return nil }
            parts.append(part)
        }
        return parts.joined(separator: "/")
    }

    /// Every file's path, in order.
    private func allPaths() -> [String] {
        guard let walker = FileManager.default.enumerator(at: files, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let base = files.resolvingSymlinksInPath().path
        var paths: [String] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            if path.hasPrefix(base + "/") { paths.append(String(path.dropFirst(base.count + 1))) }
        }
        return paths.sorted()
    }

    /// A file's text, or nil when it is missing or is not text.
    private func text(at path: String) -> String? {
        guard let data = try? Data(contentsOf: files.appendingPathComponent(path)), !data.prefix(8192).contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Paths that end the way a path the model guessed does, for "did you mean".
    private func suggestions(for path: String) -> String {
        let name = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
        let stem = name.split(separator: ".").first.map(String.init) ?? name
        let all = allPaths()
        var near = all.filter { $0.lowercased().hasSuffix("/" + name) || $0.lowercased() == name }
        if near.isEmpty, stem.count > 2 { near = all.filter { ($0.split(separator: "/").last ?? "").lowercased().contains(stem) } }
        guard !near.isEmpty else { return " Use repo_list_files or repo_search to find it." }
        return " Did you mean: " + near.prefix(6).joined(separator: ", ") + "?"
    }

    // MARK: What the tools do

    public func clone(_ text: String) async -> ToolResult {
        guard let (owner, repo) = Self.repository(in: text) else {
            return .error("Give the repository as owner/name, for example octocat/hello-world.")
        }
        if let state, state.owner.lowercased() == owner.lowercased(), state.repo.lowercased() == repo.lowercased(), !state.changed.isEmpty,
            let at = state.changedAt, Date().timeIntervalSince(at) < Self.keepChangesFor
        {
            return ToolResult(
                "\(state.owner)/\(state.repo) is already cloned, with your changes to \(state.changed.joined(separator: ", ")) kept.\n" + listing(""))
        }
        let fresh = root.appendingPathComponent("incoming", isDirectory: true)
        try? FileManager.default.removeItem(at: fresh)
        do {
            try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
            let version = try await host.download(owner: owner, repo: repo, into: fresh)
            try? FileManager.default.removeItem(at: files)
            try FileManager.default.moveItem(at: fresh, to: files)
            state = State(owner: owner, repo: repo, version: version)
            save()
        } catch {
            try? FileManager.default.removeItem(at: fresh)
            return .error("Could not clone \(owner)/\(repo): \(error.localizedDescription)")
        }
        return ToolResult("Cloned \(owner)/\(repo), branch \(state?.version.branch ?? "main"), \(allPaths().count) files.\n" + listing(""))
    }

    /// What is in a folder: everything under it when that is short, or one level with counts.
    private func listing(_ folder: String) -> String {
        let all = allPaths()
        let inside = folder.isEmpty ? all : all.filter { $0.hasPrefix(folder + "/") }
        guard !inside.isEmpty else { return "" }
        let label = folder.isEmpty ? "Files" : "Files in \(folder)/"
        if inside.count <= 60 { return "\(label):\n" + inside.joined(separator: "\n") }
        var folders: [String: Int] = [:]
        var here: [String] = []
        for path in inside {
            let rest = folder.isEmpty ? Substring(path) : path.dropFirst(folder.count + 1)
            if let slash = rest.firstIndex(of: "/") { folders[String(rest[..<slash]), default: 0] += 1 } else { here.append(String(rest)) }
        }
        let prefix = folder.isEmpty ? "" : folder + "/"
        var lines = folders.keys.sorted().map { "\(prefix)\($0)/  (\(folders[$0]!) files)" } + here.map { prefix + $0 }
        if lines.count > Self.listEntries { lines = Array(lines.prefix(Self.listEntries)) + ["and \(lines.count - Self.listEntries) more"] }
        return "\(label) (\(inside.count) in all; list a folder to see inside it):\n" + lines.joined(separator: "\n")
    }

    public func list(_ path: String) -> ToolResult {
        guard state != nil else { return .error(Self.none) }
        guard let folder = Self.clean(path) else { return .error("That path is outside the repository.") }
        let text = listing(folder)
        if text.isEmpty {
            if self.text(at: folder) != nil { return ToolResult("\(folder) is a file. Read it with repo_read_file.") }
            return .error("There is no folder \(folder)." + suggestions(for: folder))
        }
        return ToolResult(text)
    }

    public func search(_ query: String, in path: String) -> ToolResult {
        guard state != nil else { return .error(Self.none) }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .error("Give the text to search for.") }
        guard let folder = Self.clean(path) else { return .error("That path is outside the repository.") }
        // A pattern when it is one, plain text when it is not ("foo(" is no pattern).
        let pattern = (try? NSRegularExpression(pattern: query, options: [.caseInsensitive]))
            ?? (try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: query), options: [.caseInsensitive]))
        guard let pattern else { return .error("That search could not be read. Search for plain text.") }
        func matches(_ line: String) -> Bool {
            pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        var paths = allPaths().filter { folder.isEmpty || $0 == folder || $0.hasPrefix(folder + "/") }
        guard !paths.isEmpty else { return .error("There is nothing at \(folder)." + suggestions(for: folder)) }
        func isVendored(_ path: String) -> Bool { Self.vendored.contains { (path.lowercased() + "/").contains($0) || path.lowercased().hasPrefix($0) } }
        paths = paths.filter { !isVendored($0) } + paths.filter(isVendored)

        var lines: [String] = []
        var total = 0
        var filesWith = 0
        for path in paths {
            var inFile = 0
            if matches(path.split(separator: "/").last.map(String.init) ?? path) {
                total += 1
                inFile += 1
                if lines.count < Self.searchMatches { lines.append("\(path)  (the file's name matches)") }
            }
            if let size = try? files.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_000_000,
                let text = text(at: path)
            {
                for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where matches(String(line)) {
                    total += 1
                    inFile += 1
                    if lines.count < Self.searchMatches, inFile <= Self.searchMatchesPerFile {
                        lines.append("\(path):\(number + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(160))")
                    }
                }
            }
            if inFile > 0 { filesWith += 1 }
        }
        guard total > 0 else {
            return ToolResult("Nothing in \(folder.isEmpty ? "the repository" : folder) matches \"\(query)\". Try one shorter word, or list the files with repo_list_files.")
        }
        var result = lines.joined(separator: "\n")
        if total > lines.count {
            result += "\n[\(total) matches in \(filesWith) files; these are the first \(lines.count). Give `path` to search one folder or file.]"
        }
        return ToolResult(result)
    }

    public func read(_ path: String, from startLine: Int) -> ToolResult {
        guard state != nil else { return .error(Self.none) }
        guard let path = Self.clean(path), !path.isEmpty else { return .error("Give the path of a file in the repository.") }
        guard FileManager.default.fileExists(atPath: files.appendingPathComponent(path).path) else {
            return .error("There is no file \(path)." + suggestions(for: path))
        }
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: files.appendingPathComponent(path).path, isDirectory: &isFolder), isFolder.boolValue {
            return ToolResult("\(path) is a folder.\n" + listing(path))
        }
        guard let text = text(at: path) else { return .error("\(path) is not a text file.") }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let first = min(max(startLine, 1), max(lines.count, 1))
        var shown: [Substring] = []
        var characters = 0
        for line in lines.dropFirst(first - 1) {
            if !shown.isEmpty, shown.count >= Self.readLines || characters + line.count > Self.readCharacters { break }
            shown.append(line)
            characters += line.count + 1
        }
        let last = first + shown.count - 1
        var result = shown.joined(separator: "\n")
        if first > 1 || last < lines.count {
            result += "\n[Lines \(first) to \(last) of \(lines.count) in \(path)."
                + (last < lines.count ? " To read on, call repo_read_file again with start_line \(last + 1)." : " That is the end of the file.") + "]"
        }
        return ToolResult(result)
    }

    private func noteChange(_ path: String) {
        if state?.changed.contains(path) == false { state?.changed.append(path) }
        state?.changedAt = Date()
        save()
    }

    public func edit(_ path: String, find: String, replace: String) -> ToolResult {
        guard state != nil else { return .error(Self.none) }
        guard let path = Self.clean(path), !path.isEmpty else { return .error("Give the path of a file in the repository.") }
        guard FileManager.default.fileExists(atPath: files.appendingPathComponent(path).path) else {
            return .error("There is no file \(path)." + suggestions(for: path) + " To make a new file, use repo_write_file.")
        }
        guard let text = text(at: path) else { return .error("\(path) is not a text file.") }
        switch TextEdit.replace(find, with: replace, in: text, path: path) {
        case .failed(let message): return .error(message)
        case .changed(let changed):
            do { try Data(changed.utf8).write(to: files.appendingPathComponent(path)) } catch { return .error("Could not save \(path).") }
            noteChange(path)
            // The changed lines, so the model can see the edit landed where it meant.
            let before = text.split(separator: "\n", omittingEmptySubsequences: false)
            let after = changed.split(separator: "\n", omittingEmptySubsequences: false)
            var start = 0
            while start < min(before.count, after.count), before[start] == after[start] { start += 1 }
            var end = 0
            while end < min(before.count, after.count) - start, before[before.count - 1 - end] == after[after.count - 1 - end] { end += 1 }
            let now = after[start..<max(start, after.count - end)].prefix(12)
            var result = "Changed \(path). The rest of the file is as it was."
            if !now.isEmpty { result += " From line \(start + 1) it now reads:\n" + now.joined(separator: "\n") }
            return ToolResult(result + "\nWhen every change is made, call repo_open_pull_request.")
        }
    }

    public func write(_ path: String, content: String) -> ToolResult {
        guard state != nil else { return .error(Self.none) }
        guard let path = Self.clean(path), !path.isEmpty else { return .error("Give the path of the file to write.") }
        let target = files.appendingPathComponent(path)
        // Writing a whole file back from memory is how a small model loses half of it.
        if let existing = text(at: path), existing.count > 1500, content.count < existing.count * 9 / 10 {
            return .error(
                "\(path) exists and what you gave is much shorter, so nothing was changed. To change part of a file, use repo_edit_file with the text to find and what replaces it.")
        }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: target)
        } catch { return .error("Could not save \(path).") }
        noteChange(path)
        return ToolResult("Wrote \(path) (\(content.split(separator: "\n", omittingEmptySubsequences: false).count) lines). When every change is made, call repo_open_pull_request.")
    }

    public func openPullRequest(title: String, body: String) async -> ToolResult {
        guard let current = state else { return .error(Self.none) }
        guard !current.changed.isEmpty else {
            return .error("No file has been changed yet, so there is nothing to put in a pull request. Change a file with repo_edit_file first.")
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .error("Give a title that says what changed.") }
        let changes = current.changed.compactMap { path in text(at: path).map { (path: path, text: $0) } }
        let slug = Skill.slug(title).split(separator: "-").prefix(6).joined(separator: "-")
        let draft = PullRequestDraft(
            owner: current.owner, repo: current.repo, base: current.version.branch, commit: current.version.commit,
            branch: slug.isEmpty ? "change" : String(slug.prefix(48)), title: title, body: body, files: changes)
        do {
            let opened = try await host.openPullRequest(draft)
            state?.version.commit = opened.commit
            state?.changed = []
            state?.changedAt = nil
            save()
            return ToolResult(
                "Opened pull request #\(opened.number): \(opened.url)\nIt changes \(changes.map(\.path).joined(separator: ", ")) on a new branch, \(opened.branch). It is not merged. Give the user the link.")
        } catch {
            return .error("The pull request was not opened: \(error.localizedDescription) Your changes are kept.")
        }
    }
}
