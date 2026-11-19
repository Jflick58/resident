import Foundation

/// A folder of files on this device, for a model to work on the way a coding
/// agent works on a folder: list it, search it, read a file, edit it, write one.
///
/// Small models tuned for code have seen that loop endlessly, so the tools are
/// the few a coding agent has, and nothing here knows where a file came from.
/// What belongs to one service sits at the two ends, outside this type:
/// `RepositoryCopy` puts a GitHub repository in a folder of this one and opens
/// a pull request with what was changed there.
///
/// Paths are from the top of the folder. Something put here whole, such as a
/// cloned repository, is one folder in it: the project folder. Its files may
/// also be named from inside it, because the user says `web/styles.css` where
/// the tools say `rocket/web/styles.css`. One project folder is kept at a time.
public actor Workspace {
    public struct Project: Codable, Sendable {
        public var folder: String
        /// Said after a file in it is changed: what comes next.
        public var afterChange: String
    }

    struct State: Codable {
        /// Paths the tools changed, and when.
        var changed: [String: Date] = [:]
        var project: Project?
    }

    static let readLines = 200
    static let readCharacters = 4500
    static let searchMatches = 30
    static let searchMatchesPerFile = 4
    /// Files and folders named after what is searched for, shown ahead of the lines that hold it.
    static let searchNames = 8
    /// A line longer than this was not written by hand: a log, a record, a minified file. Matches in
    /// such lines are shown after the rest, as the part of the line around the match.
    static let longLine = 400
    static let listEntries = 150
    /// Folders of other people's code, searched after the rest.
    static let vendored = ["vendor/", "node_modules/", "third_party/", "pods/", ".build/", "deriveddata/", "dist/"]
    private static let outside = "That path is outside the files folder."

    /// Where what is remembered about the files is kept, and what is on its way to them.
    public nonisolated let directory: URL
    /// The folder the tools work on.
    private let files: URL
    private var state: State
    /// Looks at the files (a list, a search, a read) since the project was taken in, while nothing in it is changed.
    private var looks = 0
    /// The lines searches have shown since it was taken in.
    private var shown: Set<String> = []
    /// After this many looks with nothing changed, and every `decideAgain` after, the model is told to decide.
    static let decideAfter = 8
    static let decideAgain = 6

    /// A workspace that keeps its files in a folder of its own, beside what it remembers about them.
    public init(directory: URL) {
        self.init(files: directory.appendingPathComponent("files", isDirectory: true), records: directory)
    }

    /// A workspace over a folder that is somewhere else: one the user can see, such as the app's
    /// Documents folder, which the Files app shows under the app's name. Nothing but the files
    /// goes in it. Files a workspace kept beside its records before are moved there.
    public init(files: URL, records directory: URL) {
        self.directory = directory
        self.files = files
        let before = directory.appendingPathComponent("files", isDirectory: true)
        // An earlier version kept one cloned repository at the top of the folder, with its record in
        // state.json. That copy is dropped: the repository is downloaded again when it is next needed.
        let earlier = directory.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: earlier.path) {
            try? FileManager.default.removeItem(at: before)
            try? FileManager.default.removeItem(at: earlier)
        }
        if files.standardizedFileURL != before.standardizedFileURL,
            let kept = try? FileManager.default.contentsOfDirectory(at: before, includingPropertiesForKeys: nil)
        {
            try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            // Whatever is already there under the same name stays, and the one from before stays where it was.
            for item in kept { try? FileManager.default.moveItem(at: item, to: files.appendingPathComponent(item.lastPathComponent)) }
            if (try? FileManager.default.contentsOfDirectory(atPath: before.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: before)
            }
        }
        state = (try? Data(contentsOf: directory.appendingPathComponent("folder.json"))).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
            ?? State()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: directory.appendingPathComponent("folder.json"))
    }

    /// Forgets everything and deletes the files. The folder itself stays: it may be one the system made.
    public func reset() {
        for item in (try? FileManager.default.contentsOfDirectory(at: files, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: item)
        }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("folder.json"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("incoming"))
        state = State()
    }

    public var project: Project? { state.project }

    // MARK: Paths

    /// A path as the model gave it, made relative to the folder. Nil when it points outside.
    static func clean(_ path: String) -> String? {
        var parts: [Substring] = []
        for part in path.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/") where part != "." {
            if part == ".." { return nil }
            parts.append(part)
        }
        return parts.joined(separator: "/")
    }

    private func url(_ path: String) -> URL { path.isEmpty ? files : files.appendingPathComponent(path) }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }

    private func isFolder(_ path: String) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url(path).path, isDirectory: &folder) && folder.boolValue
    }

    /// The tools call this place the files folder, and a model takes that for its name:
    /// `files/notes.md` for `notes.md`. Read that way while nothing here is called `files`.
    private func withoutFolderName(_ path: String) -> String? {
        guard !exists("files") else { return nil }
        if path == "files" { return "" }
        return path.hasPrefix("files/") ? String(path.dropFirst(6)) : nil
    }

    /// Where a path leads: as given when something is there, otherwise inside the project folder when something is there.
    private func find(_ path: String) -> String? {
        if path.isEmpty || exists(path) { return path }
        if let project = state.project?.folder, exists(project + "/" + path) { return project + "/" + path }
        return withoutFolderName(path).flatMap { find($0) }
    }

    /// Where a new file goes: as given, unless the folder it names is only found inside the project folder.
    /// A new name at the top stays at the top, so the project folder never takes in a file meant for elsewhere.
    private func place(for path: String) -> String {
        if let existing = find(path) { return existing }
        if let inside = withoutFolderName(path), !inside.isEmpty { return place(for: inside) }
        guard let project = state.project?.folder else { return path }
        var parent = path.split(separator: "/").dropLast()
        while !parent.isEmpty {
            let folder = parent.joined(separator: "/")
            if exists(folder) { return path }
            if exists(project + "/" + folder) { return project + "/" + path }
            parent = parent.dropLast()
        }
        return path
    }

    /// Every file's path, in order.
    private func allPaths() -> [String] {
        guard let walker = FileManager.default.enumerator(at: files, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let base = files.resolvingSymlinksInPath().path
        var paths: [String] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/"), url.lastPathComponent != ".DS_Store" else { continue }
            let relative = String(path.dropFirst(base.count + 1))
            // What the Files app has deleted waits in a folder of its own at the top, and is not the user's any more.
            if relative.hasPrefix(".Trash/") { continue }
            paths.append(relative)
        }
        return paths.sorted()
    }

    public var isEmpty: Bool { allPaths().isEmpty }

    /// A file's text, or nil when it is missing or is not text.
    private func text(at path: String) -> String? {
        guard let data = try? Data(contentsOf: url(path)), !data.prefix(8192).contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A folder of this many files or fewer is named whole when something is not found in it.
    static let fewFiles = 12

    /// What to say when nothing is at a path, in words a model can stop on. Told only to list or
    /// search for it, a model asked for a file that was not there went on looking for 26 steps,
    /// through folders it had already seen. So it is told what is there: the paths that end the
    /// way its guess does, or every file when they are few, or that no name comes close.
    ///
    /// `source` is how files are got into the folder, said when there are none at all:
    /// a model that skips the clone is told to clone.
    private func missing(_ what: String, _ path: String, source: String?) -> ToolResult {
        let all = allPaths()
        guard !all.isEmpty else {
            return .error("The files folder is empty, so there is no \(what) \(path)." + (state.project == nil ? source.map { " " + $0 } ?? "" : ""))
        }
        let name = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
        let stem = name.split(separator: ".").first.map(String.init) ?? name
        var near = all.filter { $0.lowercased().hasSuffix("/" + name) || $0.lowercased() == name }
        if near.isEmpty, stem.count > 2 { near = all.filter { ($0.split(separator: "/").last ?? "").lowercased().contains(stem) } }
        var text = "There is no \(what) \(path)."
        if !near.isEmpty {
            text += " Did you mean: " + near.prefix(6).joined(separator: ", ") + "?"
        } else if all.count <= Self.fewFiles {
            text += " The files folder holds only: " + all.joined(separator: ", ") + "."
        } else {
            text += " No file in the folder has a name like that. To find one by what is in it, use \(FileTool.name(.search))."
        }
        return .error(text)
    }

    // MARK: What the tools do

    /// What is in a folder: everything under it when that is short, or one level with counts.
    public func listing(_ folder: String) -> String {
        let all = allPaths()
        var folder = folder
        let inside = folder.isEmpty ? all : all.filter { $0.hasPrefix(folder + "/") }
        guard !inside.isEmpty else { return "" }
        if inside.count <= 60 { return "\(folder.isEmpty ? "Files" : "Files in \(folder)/"):\n" + inside.joined(separator: "\n") }
        var folders: [String: Int] = [:]
        var here: [String] = []
        while true {
            folders = [:]
            here = []
            for path in inside {
                let rest = folder.isEmpty ? Substring(path) : path.dropFirst(folder.count + 1)
                if let slash = rest.firstIndex(of: "/") { folders[String(rest[..<slash]), default: 0] += 1 } else { here.append(String(rest)) }
            }
            // A folder that holds nothing but one folder is passed through: its one line would say nothing.
            guard here.isEmpty, folders.count == 1, let only = folders.keys.first else { break }
            folder = folder.isEmpty ? only : folder + "/" + only
        }
        let prefix = folder.isEmpty ? "" : folder + "/"
        var lines = folders.keys.sorted().map { "\(prefix)\($0)/  (\(folders[$0]!) files)" } + here.map { prefix + $0 }
        if lines.count > Self.listEntries { lines = Array(lines.prefix(Self.listEntries)) + ["and \(lines.count - Self.listEntries) more"] }
        return "\(folder.isEmpty ? "Files" : "Files in \(folder)/") (\(inside.count) in all; list a folder to see inside it):\n" + lines.joined(separator: "\n")
    }

    public func list(_ path: String, source: String? = nil) -> ToolResult {
        guard let given = Self.clean(path) else { return .error(Self.outside) }
        guard let folder = find(given) else { return missing("folder", given, source: source) }
        if !folder.isEmpty, !isFolder(folder) { return ToolResult("\(folder) is a file. Read it with \(FileTool.name(.read)).") }
        let text = listing(folder)
        guard text.isEmpty else { return ToolResult(text) }
        guard folder.isEmpty else { return ToolResult("\(folder)/ is empty.") }
        return ToolResult("The files folder is empty." + (state.project == nil ? source.map { " " + $0 } ?? "" : ""))
    }

    /// What one pass over some files found.
    private struct Found {
        /// Files named after what was looked for, then folders, as lines to show.
        var names: [String] = []
        /// Lines that hold it: the ones a person wrote, and the ones too long to be.
        var written: [String] = []
        var bulk: [String] = []
        var total = 0
        var filesWith = 0
    }

    /// Looks for `pattern` in the names and the text of `paths`.
    private func scan(_ paths: [String], for pattern: NSRegularExpression, perFile: Int) -> Found {
        var found = Found()
        for path in paths {
            var inFile = 0
            let name = path.split(separator: "/").last.map(String.init) ?? path
            if pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
                found.total += 1
                inFile += 1
                found.names.append("\(path)  (the file's name matches)")
            }
            if let size = try? url(path).resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_000_000, let text = text(at: path) {
                for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let line = String(line)
                    guard let hit = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
                    found.total += 1
                    inFile += 1
                    guard inFile <= perFile else { continue }
                    if line.count <= Self.longLine {
                        if found.written.count < Self.searchMatches {
                            found.written.append("\(path):\(number + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(160))")
                        }
                    } else if found.bulk.count < Self.searchMatches, let range = Range(hit.range, in: line) {
                        let from = line.index(range.lowerBound, offsetBy: -60, limitedBy: line.startIndex) ?? line.startIndex
                        let to = line.index(range.upperBound, offsetBy: 100, limitedBy: line.endIndex) ?? line.endIndex
                        found.bulk.append("\(path):\(number + 1): \(from > line.startIndex ? "…" : "")\(line[from..<to])\(to < line.endIndex ? "…" : "")")
                    }
                }
            }
            if inFile > 0 { found.filesWith += 1 }
        }
        return found
    }

    /// The folders among `paths` whose own names match `pattern`, each as a line to show.
    /// A folder that holds everything searched is where the search was made, not something it found.
    private func folders(in paths: [String], named pattern: NSRegularExpression) -> [(folder: String, line: String)] {
        var holds: [String: [String]] = [:]
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            for depth in parts.indices.dropLast() where pattern.firstMatch(in: parts[depth], range: NSRange(parts[depth].startIndex..., in: parts[depth])) != nil {
                holds[parts[...depth].joined(separator: "/"), default: []].append(parts[(depth + 1)...].joined(separator: "/"))
            }
        }
        return holds.keys.sorted().filter { holds[$0]!.count < paths.count }.map { folder in
            let inside = holds[folder]!
            return (
                folder,
                "\(folder)/  (the folder's name matches; " + (inside.count <= 3 ? "it holds \(inside.joined(separator: ", "))" : "\(inside.count) files") + ")"
            )
        }
    }

    public func search(_ query: String, in path: String, source: String? = nil) -> ToolResult {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .error("Give the text to search for.") }
        guard let given = Self.clean(path) else { return .error(Self.outside) }
        guard let folder = find(given) else { return missing("file or folder", given, source: source) }
        let paths = allPaths().filter { folder.isEmpty || $0 == folder || $0.hasPrefix(folder + "/") }
        guard !paths.isEmpty else {
            guard folder.isEmpty else { return .error("\(folder)/ is empty, so there is nothing to search.") }
            return .error("The files folder is empty, so there is nothing to search." + (state.project == nil ? source.map { " " + $0 } ?? "" : ""))
        }
        // The text as it is written, and a pattern only when that finds nothing. What a model searches
        // for is mostly code, and code read as a pattern finds far more than was meant: `.tint` is
        // also the middle of "ComponentIntegration".
        guard let plain = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: query), options: [.caseInsensitive]) else {
            return .error("That search could not be read. Search for plain text.")
        }
        func isVendored(_ path: String) -> Bool { Self.vendored.contains { (path.lowercased() + "/").contains($0) || path.lowercased().hasPrefix($0) } }
        // The project's own files, then other people's code kept with it.
        let groups = [paths.filter { !isVendored($0) }, paths.filter(isVendored)]
        // One file searched on its own shows every match, up to the limit.
        let perFile = paths.count == 1 ? Self.searchMatches : Self.searchMatchesPerFile
        // The project's files and the others, each with the files, the folders and the lines found.
        func look(for pattern: NSRegularExpression) -> [Found] {
            var found = groups.map { scan($0, for: pattern, perFile: perFile) }
            for (folder, line) in folders(in: paths, named: pattern) {
                let group = isVendored(folder + "/") ? 1 : 0
                found[group].names.append(line)
                found[group].total += 1
            }
            return found
        }
        var found = look(for: plain)
        if found.allSatisfy({ $0.total == 0 }), let pattern = try? NSRegularExpression(pattern: query, options: [.caseInsensitive]),
            pattern.pattern != plain.pattern
        {
            found = look(for: pattern)
        }
        let total = found.reduce(0) { $0 + $1.total }
        guard total > 0 else {
            // Searched whole, a folder of a few files has been looked through: saying so lets the model stop.
            let all = folder.isEmpty && paths.count <= Self.fewFiles
            return ToolResult(
                "Nothing in \(folder.isEmpty ? "the files" : folder) matches \"\(query)\"."
                    + (all
                        ? " That was every file: " + paths.joined(separator: ", ") + "."
                        : " Try one shorter word, or list the files with \(FileTool.name(.list))."))
        }
        // Names come before the lines. A file or folder called after what is looked for is the
        // likeliest place for it, and may hold no line that says the word: asked to change an app's
        // accent colour, a model searched for "accent", was shown the one line of code that uses the
        // colour, and took 13 more calls to believe that `AccentColor.colorset/Contents.json` was
        // where it is set. Lines too long to have been written by hand come last of all.
        var lines: [String] = []
        var names = 0
        for group in found {
            let named = group.names.prefix(Self.searchNames - names)
            names += named.count
            lines += named
            lines += group.written.prefix(max(0, Self.searchMatches - lines.count))
        }
        lines += found.flatMap(\.bulk).prefix(max(0, Self.searchMatches - lines.count))
        lines = Array(lines.prefix(Self.searchMatches))
        var result = lines.joined(separator: "\n")
        if total > lines.count {
            result += "\n[\(total) matches in \(found.reduce(0) { $0 + $1.filesWith }) files; these are the first \(lines.count). Give `path` to search one folder or file.]"
        }
        // A search worded another way that finds only what was found before has found the end of it.
        // Left to work that out, a model looking for where a colour was defined ran the search five
        // ways, and went on to read files that never mention it. Said only of a search shown whole.
        if state.project != nil, total == lines.count, shown.isSuperset(of: lines) {
            result += "\n[Nothing new: your earlier searches showed every one of these. Searching for this another way will not find more.]"
        }
        shown.formUnion(lines)
        return ToolResult(result)
    }

    public func read(_ path: String, from startLine: Int, source: String? = nil) -> ToolResult {
        guard let given = Self.clean(path), !given.isEmpty else { return .error("Give the path of a file.") }
        guard let path = find(given) else { return missing("file", given, source: source) }
        if isFolder(path) { return ToolResult("\(path) is a folder.\n" + listing(path)) }
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
                + (last < lines.count
                    ? " To read on, call \(FileTool.name(.read)) again with start_line \(last + 1). To find one thing in this file, call \(FileTool.name(.search)) with this path."
                    : " That is the end of the file.") + "]"
        }
        return ToolResult(result)
    }

    private func noteChange(_ path: String) {
        state.changed[path] = Date()
        save()
    }

    /// Counts a look at the files (a list, a search, a read) and returns its result, with a line put
    /// before it when looks have piled up with nothing changed.
    ///
    /// A small model that has found the place for a change goes on looking for a better one. Asked to
    /// change an app's accent colour, LFM3 read the file that sets it on its fifth call and made twenty
    /// more looking for where the colour was "defined", until its turn ran out. What it needed was to
    /// be told to choose: make the change, or ask. Where it is told matters as much as what. At the
    /// end of a long result the line went unread. In place of the result, it was taken for the tool
    /// failing ("maybe the tool requires a different format?") and the same call made again. So it
    /// comes first, and the result follows.
    /// Only with a project in the folder, and until something in it is changed: files of the user's
    /// own are for reading too, and a model that has made its change may check it.
    public func counted(_ result: ToolResult) -> ToolResult {
        guard let project = state.project, changes(under: project.folder).isEmpty else { return result }
        looks += 1
        guard looks >= Self.decideAfter, (looks - Self.decideAfter) % Self.decideAgain == 0 else { return result }
        var result = result
        result.text =
            "[Before this result: that is \(looks) lookups in \(project.folder)/ and no file is changed. You have enough to act. "
            + "Next, do one of two things: (1) call \(FileTool.name(.edit)) to make the change in the best place you have read, "
            + "or (2) tell the user what you found and ask the one thing you still need to know. "
            + "Look further only at something you have not looked at yet.]\n\n" + result.text
        return result
    }

    /// What follows a change to this path, when it is in the project folder.
    private func next(after path: String) -> String? {
        guard let project = state.project, path.hasPrefix(project.folder + "/") else { return nil }
        return project.afterChange
    }

    public func edit(_ path: String, find: String, replace: String, source: String? = nil) -> ToolResult {
        guard let given = Self.clean(path), !given.isEmpty else { return .error("Give the path of a file.") }
        guard let path = self.find(given), !isFolder(path) else {
            var result = missing("file", given, source: source)
            result.text += " To make a new file, use \(FileTool.name(.write))."
            return result
        }
        guard let text = text(at: path) else { return .error("\(path) is not a text file.") }
        switch TextEdit.replace(find, with: replace, in: text, path: path) {
        case .failed(let message): return .error(message)
        case .changed(let changed):
            if let broken = Self.brokenJSON(changed, was: text, path: path) { return .error(broken) }
            do { try Data(changed.utf8).write(to: url(path)) } catch { return .error("Could not save \(path).") }
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
            return ToolResult(result + (next(after: path).map { "\n" + $0 } ?? ""))
        }
    }

    /// What to say when a change would leave a JSON file that no longer reads as JSON, and nil when
    /// it would not or the file did not read as JSON before. A file with one right form can be
    /// checked, and a change that breaks it is never what was meant: asked for a green accent colour,
    /// a model put `"green" : "0.42" -> "green" : "0.80"` in an asset's JSON and opened a pull request with it.
    static func brokenJSON(_ changed: String, was text: String, path: String) -> String? {
        guard path.lowercased().hasSuffix(".json"), (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) != nil
        else { return nil }
        do {
            _ = try JSONSerialization.jsonObject(with: Data(changed.utf8), options: [.fragmentsAllowed])
            return nil
        } catch {
            let reason = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? "it would not read as JSON"
            return "Nothing was changed: with that, \(path) would no longer be valid JSON (\(reason)). Put only the new value in `replace`, in the same form as the text it takes the place of."
        }
    }

    public func write(_ path: String, content: String) -> ToolResult {
        guard let given = Self.clean(path), !given.isEmpty else { return .error("Give the path of the file to write.") }
        let path = place(for: given)
        guard !isFolder(path) else { return .error("\(path) is a folder. Give the path of a file in it.") }
        let isNew = !exists(path)
        // Writing a whole file back from memory is how a small model loses half of it.
        if let existing = text(at: path), existing.count > 1500, content.count < existing.count * 9 / 10 {
            return .error(
                "\(path) exists and what you gave is much shorter, so nothing was changed. To change part of a file, use \(FileTool.name(.edit)) with the text to find and what replaces it.")
        }
        if let existing = text(at: path), let broken = Self.brokenJSON(content, was: existing, path: path) { return .error(broken) }
        do {
            try FileManager.default.createDirectory(at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url(path))
        } catch { return .error("Could not save \(path).") }
        noteChange(path)
        var result = "Wrote \(path) (\(content.split(separator: "\n", omittingEmptySubsequences: false).count) lines)."
        if let next = next(after: path) {
            result += " " + next
        } else if isNew, let project = state.project {
            // A new file for the project, named without its folder, would otherwise be left out of what is done with the project.
            result += " It is outside \(project.folder)/. A file that belongs to \(project.folder) has a path that starts with \(project.folder)/."
        }
        return ToolResult(result)
    }

    // MARK: For what puts files here

    /// Takes in a folder made elsewhere, such as a downloaded repository, as the project folder,
    /// and returns the name it has here. The project folder before it makes way.
    public func adopt(_ incoming: URL, named name: String, afterChange: String) throws -> String {
        if let earlier = state.project?.folder {
            try? FileManager.default.removeItem(at: url(earlier))
            forget(under: earlier)
            state.project = nil
        }
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        // Never over files that are not a project's: a folder of that name the model made keeps it.
        let wanted = Self.clean(name).flatMap { $0.isEmpty || $0.contains("/") ? nil : $0 } ?? "project"
        var folder = wanted
        var number = 2
        while exists(folder) {
            folder = "\(wanted)-\(number)"
            number += 1
        }
        try FileManager.default.moveItem(at: incoming, to: url(folder))
        // A copy of something that can be downloaded again has no place in a backup of the device.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var placed = url(folder)
        try? placed.setResourceValues(values)
        state.project = Project(folder: folder, afterChange: afterChange)
        looks = 0
        shown = []
        save()
        return folder
    }

    /// The files under a folder that the tools changed, by path, each with when it last was.
    public func changes(under folder: String) -> [(path: String, at: Date)] {
        state.changed.filter { $0.key.hasPrefix(folder + "/") }.sorted { $0.key < $1.key }.map { (path: $0.key, at: $0.value) }
    }

    private func forget(under folder: String) {
        state.changed = state.changed.filter { !$0.key.hasPrefix(folder + "/") }
    }

    /// Notes that the changes under a folder have gone where they were meant to.
    public func forgetChanges(under folder: String) {
        forget(under: folder)
        save()
    }

    /// The text of each of these files that is one.
    public func texts(of paths: [String]) -> [(path: String, text: String)] {
        paths.compactMap { path in text(at: path).map { (path: path, text: $0) } }
    }

    /// How many files a folder holds.
    public func count(under folder: String) -> Int {
        allPaths().filter { $0.hasPrefix(folder + "/") }.count
    }
}
