import Foundation
import Testing

@testable import HarnessKit

@Suite struct TextEditTests {
    let file = "body {\n  margin: 0;\n  background: #ffffff;\n}\n\nh1 {\n  margin: 0;\n}\n"

    @Test func replacesTextFoundOnce() {
        #expect(TextEdit.replace("#ffffff", with: "pink", in: file, path: "a.css") == .changed(file.replacingOccurrences(of: "#ffffff", with: "pink")))
    }

    @Test func forgivesSpaceAtTheEnds() {
        #expect(TextEdit.replace("\nbackground: #ffffff;\n", with: "background: pink;", in: file, path: "a.css")
            == .changed(file.replacingOccurrences(of: "#ffffff", with: "pink")))
    }

    @Test func forgivesWrongIndentationOverSeveralLines() {
        let result = TextEdit.replace("body {\nmargin: 0;\nbackground: #ffffff;\n}", with: "body {\n  background: pink;\n}", in: file, path: "a.css")
        #expect(result == .changed("body {\n  background: pink;\n}\n\nh1 {\n  margin: 0;\n}\n"))
    }

    @Test func refusesTextFoundTwice() {
        guard case .failed(let message) = TextEdit.replace("margin: 0;", with: "margin: 1px;", in: file, path: "a.css") else {
            Issue.record("should fail")
            return
        }
        #expect(message.contains("2 times"))
    }

    @Test func namesTheClosestLineWhenNothingMatches() {
        guard case .failed(let message) = TextEdit.replace("background: white;", with: "x", in: file, path: "a.css") else {
            Issue.record("should fail")
            return
        }
        #expect(message.contains("background: #ffffff;"))
    }
}

@Suite struct WorkspaceTests {
    static let guide = (1...400).map { "Step \($0): check the gauge." }.joined(separator: "\n")

    /// A folder with nothing in it, and the file tools on their own.
    func plain() -> (Workspace, [String: any Tool]) {
        let workspace = Workspace(directory: FileManager.default.temporaryDirectory.appendingPathComponent("workspace-\(UUID().uuidString)"))
        return (workspace, Dictionary(uniqueKeysWithValues: FileTool.group(workspace: workspace).tools.map { ($0.spec.name, $0) }))
    }

    /// The same with GitHub's two tools beside them, and a made-up GitHub that holds acme/rocket.
    func make(files: [String: String]? = nil) -> (Workspace, FixedRepositoryHost, [String: any Tool]) {
        let host = FixedRepositoryHost(
            owner: "acme", repo: "rocket",
            files: files ?? [
                "README.md": "# Rokcet\n\nFuel tools.\n", "web/styles.css": "body {\n  margin: 0;\n  background: #ffffff;\n}\n",
                "src/gauge.py": "OFFSET = 12\n\n\ndef read_fuel_level(sensor):\n    return sensor.raw - OFFSET\n", "docs/GUIDE.md": Self.guide,
            ])
        let workspace = Workspace(directory: FileManager.default.temporaryDirectory.appendingPathComponent("workspace-\(UUID().uuidString)"))
        let group = FileTool.group(workspace: workspace, repository: RepositoryCopy(workspace: workspace, host: host))
        return (workspace, host, Dictionary(uniqueKeysWithValues: group.tools.map { ($0.spec.name, $0) }))
    }

    // MARK: Files of any kind

    @Test func theFileToolsNeedNoRepository() async {
        let (_, tools) = plain()
        #expect(tools.keys.sorted() == ["edit_file", "list_files", "read_file", "search_files", "write_file"])
        let empty = await tools["list_files"]!.call([:])
        #expect(!empty.isError && empty.text == "The files folder is empty.")

        let wrote = await tools["write_file"]!.call(["path": "notes/todo.md", "content": "- buy milk\n- call Sam\n"])
        #expect(wrote.text == "Wrote notes/todo.md (3 lines).")
        #expect(await tools["list_files"]!.call([:]).text == "Files:\nnotes/todo.md")
        #expect(await tools["read_file"]!.call(["path": "notes/todo.md"]).text == "- buy milk\n- call Sam\n")
        #expect(await tools["search_files"]!.call(["query": "sam"]).text == "notes/todo.md:2: - call Sam")

        let edit = await tools["edit_file"]!.call(["path": "notes/todo.md", "find": "call Sam", "replace": "call Sam at 5"])
        #expect(!edit.isError && edit.text.hasPrefix("Changed notes/todo.md.") && !edit.text.contains("pull"))
        #expect(await tools["read_file"]!.call(["path": "notes/todo.md"]).text == "- buy milk\n- call Sam at 5\n")
    }

    @Test func anEmptyFolderSaysToCloneOnlyWhereThatCanBeDone() async {
        let (_, alone) = plain()
        let none = await alone["read_file"]!.call(["path": "README.md"])
        #expect(none.isError && none.text == "The files folder is empty, so there is no file README.md.")

        let (_, _, tools) = make()
        let before = await tools["read_file"]!.call(["path": "README.md"])
        #expect(before.isError && before.text.contains("repo_clone"))
        #expect(await tools["list_files"]!.call([:]).text.contains("repo_clone"))
        #expect(await tools["search_files"]!.call(["query": "background"]).text.contains("repo_clone"))
        // Once there are files, a wrong path is only a wrong path, with a repository or without.
        _ = await tools["write_file"]!.call(["path": "todo.md", "content": "- milk\n"])
        #expect(!(await tools["read_file"]!.call(["path": "budget.md"]).text.contains("repo_clone")))
        _ = await tools["repo_clone"]!.call(["repository": "acme/rocket"])
        let after = await tools["read_file"]!.call(["path": "nothing.md"])
        #expect(after.isError && !after.text.contains("repo_clone"))
    }

    @Test func aFileThatIsNotThereIsSaidNotToBe() async {
        // In words a model can stop on, not an invitation to keep looking.
        let (_, tools) = plain()
        _ = await tools["write_file"]!.call(["path": "todo.md", "content": "- milk\n"])
        _ = await tools["write_file"]!.call(["path": "notes/trip.md", "content": "Lisbon\n"])
        let missing = await tools["read_file"]!.call(["path": "budget.md"])
        #expect(missing.isError && missing.text == "There is no file budget.md. The files folder holds only: notes/trip.md, todo.md.")
        let nothing = await tools["search_files"]!.call(["query": "budget"])
        #expect(!nothing.isError && nothing.text == "Nothing in the files matches \"budget\". That was every file: notes/trip.md, todo.md.")
        let folder = await tools["list_files"]!.call(["path": "finances"])
        #expect(folder.isError && folder.text.hasPrefix("There is no folder finances. The files folder holds only:"))

        // With more files than can be named, it is said that no name comes close, and how else to look.
        for number in 1...20 { _ = await tools["write_file"]!.call(["path": .string("log/day\(number).md"), "content": "A day\n"]) }
        let many = await tools["read_file"]!.call(["path": "budget.md"])
        #expect(many.text == "There is no file budget.md. No file in the folder has a name like that. To find one by what is in it, use search_files.")
        let searched = await tools["search_files"]!.call(["query": "budget"])
        #expect(searched.text.hasSuffix("Try one shorter word, or list the files with list_files."))
    }

    @Test func theFolderIsNotAFolderNamedFiles() async {
        // "The files folder" is what the tools call the place, not a folder in it.
        let (_, tools) = plain()
        let wrote = await tools["write_file"]!.call(["path": "/files/notes/todo.md", "content": "- milk\n"])
        #expect(wrote.text.hasPrefix("Wrote notes/todo.md"))
        #expect(await tools["read_file"]!.call(["path": "files/notes/todo.md"]).text == "- milk\n")
        #expect(await tools["list_files"]!.call(["path": "files"]).text == "Files:\nnotes/todo.md")
        // Unless there is one: a repository of that name, cloned.
        let workspace = Workspace(directory: FileManager.default.temporaryDirectory.appendingPathComponent("workspace-\(UUID().uuidString)"))
        let host = FixedRepositoryHost(owner: "acme", repo: "files", files: ["README.md": "# Files\n"])
        _ = await RepositoryCopy(workspace: workspace, host: host).clone("acme/files")
        #expect(await workspace.write("files/notes.md", content: "x\n").text.hasPrefix("Wrote files/notes.md"))
        #expect(await workspace.list("files").text == "Files in files/:\nfiles/README.md\nfiles/notes.md")
    }

    @Test func pathsOutsideTheFolderAreRefused() async {
        let (_, tools) = plain()
        _ = await tools["write_file"]!.call(["path": "a.txt", "content": "a"])
        #expect(await tools["read_file"]!.call(["path": "../../etc/passwd"]).isError)
        #expect(await tools["write_file"]!.call(["path": "../b.txt", "content": "b"]).isError)
        #expect(await tools["list_files"]!.call(["path": ".."]).isError)
    }

    @Test func anEarlierLayoutIsDropped() async throws {
        // Before the file tools were general, one repository lay at the top of the folder.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("files"), withIntermediateDirectories: true)
        try Data("# Rocket\n".utf8).write(to: directory.appendingPathComponent("files/README.md"))
        try Data(#"{"owner":"acme","repo":"rocket","version":{"branch":"main","commit":"c0ffee0"},"changed":[]}"#.utf8)
            .write(to: directory.appendingPathComponent("state.json"))
        let workspace = Workspace(directory: directory)
        #expect(await workspace.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.json").path))
    }

    // MARK: A repository in the folder

    @Test func cloneListsTheFiles() async {
        let (_, _, tools) = make()
        let result = await tools["repo_clone"]!.call(["repository": "https://github.com/acme/rocket"])
        #expect(!result.isError)
        #expect(result.text.hasPrefix("Cloned acme/rocket into rocket/, branch main, 4 files.\nFiles in rocket/:"))
        #expect(result.text.contains("rocket/web/styles.css"))
        let missing = await tools["repo_clone"]!.call(["repository": "acme/other"])
        #expect(missing.isError)
    }

    @Test func cloneTakesOwnerAndRepoApart() async {
        let (_, _, tools) = make()
        let result = await tools["repo_clone"]!.call(["owner": "acme", "repo": "rocket"])
        #expect(!result.isError)
        #expect(RepositoryCopy.repository(in: "git@github.com:acme/rocket.git")! == ("acme", "rocket"))
        // Not a name that would lead out of the folder.
        #expect(RepositoryCopy.repository(in: "acme/..") == nil)
    }

    @Test func searchFindsLinesAndFileNames() async {
        let (_, _, tools) = make()
        _ = await tools["repo_clone"]!.call(["repository": "acme/rocket"])
        let lines = await tools["search_files"]!.call(["query": "BACKGROUND"])
        #expect(lines.text == "rocket/web/styles.css:3: background: #ffffff;")
        let pattern = await tools["search_files"]!.call(["query": "bg|background|colou?r"])
        #expect(pattern.text.contains("rocket/web/styles.css:3"))
        let name = await tools["search_files"]!.call(["query": "readme"])
        #expect(name.text.contains("rocket/README.md  (the file's name matches)"))
        // A folder of the repository, named the way the user would.
        let many = await tools["search_files"]!.call(["query": "gauge", "path": "docs"])
        #expect(many.text.contains("400 matches in 1 files"))
        let nothing = await tools["search_files"]!.call(["query": "zebra"])
        #expect(!nothing.isError && nothing.text.contains("Nothing"))
    }

    @Test func readGivesALongFileInParts() async {
        let (_, _, tools) = make()
        _ = await tools["repo_clone"]!.call(["repository": "acme/rocket"])
        let first = await tools["read_file"]!.call(["path": "rocket/docs/GUIDE.md"])
        #expect(first.text.hasPrefix("Step 1: check the gauge."))
        #expect(first.text.contains("call read_file again with start_line"))
        #expect(first.text.count < 6000)
        let last = await tools["read_file"]!.call(["path": "docs/GUIDE.md", "start_line": 395])
        #expect(last.text.hasPrefix("Step 395") && last.text.contains("Lines 395 to 400 of 400 in rocket/docs/GUIDE.md") && last.text.contains("end of the file"))
    }

    @Test func aRepositoryFileMayBeNamedFromInsideItsFolder() async {
        let (_, _, tools) = make()
        _ = await tools["write_file"]!.call(["path": "README.md", "content": "Mine\n"])
        _ = await tools["repo_clone"]!.call(["repository": "acme/rocket"])
        let inside = await tools["read_file"]!.call(["path": "web/styles.css"])
        let whole = await tools["read_file"]!.call(["path": "rocket/web/styles.css"])
        #expect(!inside.isError && inside.text == whole.text)
        #expect(await tools["list_files"]!.call(["path": "web"]).text == "Files in rocket/web/:\nrocket/web/styles.css")
        // What is at the top under that name comes first.
        #expect(await tools["read_file"]!.call(["path": "README.md"]).text == "Mine\n")
        #expect(await tools["read_file"]!.call(["path": "rocket/README.md"]).text.hasPrefix("# Rokcet"))
        // The same path is the same file for every tool: written whole, it is still the repository's.
        let rewritten = await tools["write_file"]!.call(["path": "web/styles.css", "content": "body { margin: 0; }\n"])
        #expect(rewritten.text.hasPrefix("Wrote rocket/web/styles.css") && rewritten.text.contains("repo_open_pull_request"))
    }

    @Test func aGuessedPathIsCorrected() async {
        let (_, _, tools) = make()
        _ = await tools["repo_clone"]!.call(["repository": "acme/rocket"])
        let result = await tools["read_file"]!.call(["path": "styles.css"])
        #expect(result.isError && result.text.contains("Did you mean: rocket/web/styles.css?"))
    }

    @Test func editThenPullRequestSendsTheWholeChangedFile() async {
        let (_, host, tools) = make()
        let early = await tools["repo_open_pull_request"]!.call(["title": "Pink"])
        #expect(early.isError && early.text.contains("repo_clone"))
        _ = await tools["repo_clone"]!.call(["repository": "acme/rocket"])
        let none = await tools["repo_open_pull_request"]!.call(["title": "Pink"])
        #expect(none.isError && none.text.contains("edit_file"))

        let edit = await tools["edit_file"]!.call(["path": "web/styles.css", "find": "background: #ffffff;", "replace": "background: pink;"])
        #expect(!edit.isError && edit.text.hasPrefix("Changed rocket/web/styles.css."))
        #expect(edit.text.contains("From line 3 it now reads:\n  background: pink;") && edit.text.hasSuffix("call repo_open_pull_request."))
        let opened = await tools["repo_open_pull_request"]!.call(["title": "Make the page background pink", "body": "As asked."])
        #expect(opened.text.contains("https://github.com/acme/rocket/pull/42") && opened.text.contains("It changes web/styles.css on"))
        let draft = host.pullRequests[0]
        #expect(draft.base == "main" && draft.commit == "c0ffee0" && draft.branch == "make-the-page-background-pink")
        // GitHub gets the path in the repository, without the folder it is kept in here.
        #expect(draft.files.count == 1 && draft.files[0].path == "web/styles.css")
        #expect(draft.files[0].text == "body {\n  margin: 0;\n  background: pink;\n}\n")

        let again = await tools["repo_open_pull_request"]!.call(["title": "Pink"])
        #expect(again.isError)
    }

    @Test func cloningAgainKeepsFreshChanges() async {
        let (_, _, tools) = make()
        _ = await tools["repo_clone"]!.call(["repository": "acme/rocket"])
        _ = await tools["edit_file"]!.call(["path": "rocket/README.md", "find": "Rokcet", "replace": "Rocket"])
        let again = await tools["repo_clone"]!.call(["repository": "acme/rocket"])
        #expect(again.text.contains("already cloned in rocket/") && again.text.contains("rocket/README.md"))
        let read = await tools["read_file"]!.call(["path": "rocket/README.md"])
        #expect(read.text.hasPrefix("# Rocket"))
    }

    @Test func writeMakesNewFilesAndWillNotShortenLongOnes() async {
        let (_, host, tools) = make()
        _ = await tools["repo_clone"]!.call(["repository": "acme/rocket"])
        // In a folder that only the repository has, so it is the repository's.
        let new = await tools["write_file"]!.call(["path": "docs/NOTES.md", "content": "# Notes\n"])
        #expect(!new.isError && new.text.hasPrefix("Wrote rocket/docs/NOTES.md") && new.text.contains("repo_open_pull_request"))
        let short = await tools["write_file"]!.call(["path": "docs/GUIDE.md", "content": "Step 1: check the gauge.\n"])
        #expect(short.isError && short.text.contains("edit_file"))
        _ = await tools["repo_open_pull_request"]!.call(["title": "Add notes"])
        #expect(host.pullRequests[0].files.map(\.path) == ["docs/NOTES.md"])
    }

    @Test func aNewFileAtTheTopIsNotTakenIntoTheRepository() async {
        let (_, host, tools) = make()
        _ = await tools["repo_clone"]!.call(["repository": "acme/rocket"])
        let stray = await tools["write_file"]!.call(["path": "LICENSE", "content": "MIT\n"])
        #expect(!stray.isError && stray.text.contains("outside rocket/") && stray.text.contains("starts with rocket/"))
        let none = await tools["repo_open_pull_request"]!.call(["title": "Add a licence"])
        #expect(none.isError && none.text.contains("No file in rocket/"))

        let meant = await tools["write_file"]!.call(["path": "rocket/LICENSE", "content": "MIT\n"])
        #expect(meant.text.hasPrefix("Wrote rocket/LICENSE") && meant.text.contains("repo_open_pull_request"))
        _ = await tools["repo_open_pull_request"]!.call(["title": "Add a licence"])
        #expect(host.pullRequests[0].files.map(\.path) == ["LICENSE"])
    }

    @Test func aCloneLeavesOtherFilesAlone() async {
        let (_, _, tools) = make()
        _ = await tools["write_file"]!.call(["path": "notes.md", "content": "Mine\n"])
        _ = await tools["write_file"]!.call(["path": "rocket/plan.txt", "content": "Also mine\n"])
        // A folder of the repository's name is already there and is not the repository: it keeps the name.
        let cloned = await tools["repo_clone"]!.call(["repository": "acme/rocket"])
        #expect(cloned.text.hasPrefix("Cloned acme/rocket into rocket-2/"))
        #expect(await tools["read_file"]!.call(["path": "notes.md"]).text == "Mine\n")
        #expect(await tools["read_file"]!.call(["path": "rocket/plan.txt"]).text == "Also mine\n")
        let top = await tools["list_files"]!.call([:])
        #expect(top.text.contains("notes.md") && top.text.contains("rocket-2/README.md") && top.text.contains("rocket/plan.txt"))

        // Cloned again with nothing changed, it is downloaded afresh into the same place.
        let again = await tools["repo_clone"]!.call(["repository": "acme/rocket"])
        #expect(again.text.hasPrefix("Cloned acme/rocket into rocket-2/"))
        #expect(await tools["read_file"]!.call(["path": "notes.md"]).text == "Mine\n")
    }

    @Test func aLargeRepositoryIsListedAFolderAtATime() async {
        var files: [String: String] = [:]
        for number in 1...40 { files["src/part\(number).py"] = "x = \(number)\n" }
        for number in 1...30 { files["docs/page\(number).md"] = "Page \(number)\n" }
        let (_, _, tools) = make(files: files)
        let cloned = await tools["repo_clone"]!.call(["repository": "acme/rocket"])
        #expect(cloned.text.contains("Files in rocket/ (70 in all; list a folder to see inside it):\nrocket/docs/  (30 files)\nrocket/src/  (40 files)"))
        // The top holds only the repository, so listing it shows the repository.
        #expect(await tools["list_files"]!.call([:]).text.hasPrefix("Files in rocket/ (70 in all"))
        #expect(await tools["list_files"]!.call(["path": "docs"]).text.hasPrefix("Files in rocket/docs/:\nrocket/docs/page1.md"))
    }

    @Test func stateOutlastsTheProcess() async {
        let host = FixedRepositoryHost(owner: "acme", repo: "rocket", files: ["README.md": "# Rokcet\n"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-\(UUID().uuidString)")
        let first = Workspace(directory: directory)
        _ = await RepositoryCopy(workspace: first, host: host).clone("acme/rocket")
        _ = await first.edit("README.md", find: "Rokcet", replace: "Rocket")
        let second = Workspace(directory: directory)
        let opened = await RepositoryCopy(workspace: second, host: host).openPullRequest(title: "Fix the title", body: "")
        #expect(!opened.isError && host.pullRequests[0].files[0].text == "# Rocket\n")
        #expect(host.pullRequests[0].files[0].path == "README.md")
    }
}

@Suite struct FilesConnectorTests {
    private func group(withRepository: Bool) -> ToolGroup {
        let workspace = Workspace(directory: FileManager.default.temporaryDirectory.appendingPathComponent("workspace-\(UUID().uuidString)"))
        let host = FixedRepositoryHost(owner: "acme", repo: "rocket", files: [:])
        return FileTool.group(workspace: workspace, repository: withRepository ? RepositoryCopy(workspace: workspace, host: host) : nil)
    }

    @Test func gitHubAddsOnlyTheTwoEnds() {
        let plain = group(withRepository: false)
        #expect(plain.name == "files" && plain.title == "Files")
        #expect(plain.tools.map(\.spec.name) == ["list_files", "search_files", "read_file", "edit_file", "write_file"])
        #expect(!plain.promptLine.lowercased().contains("github") && !plain.promptLine.contains("repositor"))
        for tool in plain.tools { #expect(!tool.spec.parameters.jsonString.lowercased().contains("repositor") && !tool.spec.description.contains("GitHub")) }

        let with = group(withRepository: true)
        #expect(with.tools.map(\.spec.name) == ["repo_clone", "list_files", "search_files", "read_file", "edit_file", "write_file", "repo_open_pull_request"])
        // Opened whole, and by a message that names a repository.
        #expect(with.tools.count <= ToolGroup.wholeLimit)
        var shelf = ToolShelf(groups: [with])
        let opened = shelf.preload(for: "Open a pull request on acme/rocket that makes the background orange")
        #expect(opened && shelf.loaded.count == 7)
        var alone = ToolShelf(groups: [plain])
        let openedAlone = alone.preload(for: "Open a pull request on acme/rocket that makes the background orange")
        #expect(!openedAlone)
    }

    @Test func thePullRequestSkillGoesWithTheToolsItNeeds() {
        let skill = Skill.builtIns.first { $0.name == "open-pull-request" }!
        let with = ToolGroup.linking([group(withRepository: true)], to: Skill.builtIns)
        #expect(with[0].skillHints == ["\(skill.name): \(skill.summary)"])
        // Without GitHub the skill cannot be followed, and is not offered to a model that wants to save a note.
        let plain = ToolGroup.linking([group(withRepository: false)], to: Skill.builtIns, absent: RepositoryTool.names)
        #expect(plain[0].skillHints.isEmpty)
        // A skill about files alone is offered either way.
        let notes = Skill(name: "daily-note", summary: "Keeping the daily note", instructions: "Add the line to notes/today.md with `edit_file`.")
        #expect(ToolGroup.linking([group(withRepository: false)], to: [notes], absent: RepositoryTool.names)[0].skillHints.count == 1)
    }

    @Test func aSavedCopyOfThePullRequestSkillTakesTheNewNames() {
        var saved = Skill.builtIns.first { $0.name == "open-pull-request" }!
        saved.instructions = """
            4. Read the file with `repo_read_file`.
            8. Give the user the pull request's link. Do not merge it.
            Do not change files with the github_ tools: they need the whole file written back.
            If a step fails, read the error and try that step again before going on.
            """
        let current = saved.withCurrentInstructions.instructions
        #expect(current.contains("`read_file`") && !current.contains("repo_read_file"))
        for name in FileTool.Kind.allCases.map(\.rawValue) + RepositoryTool.names { #expect(ToolGroup.names(name, in: current)) }
    }

    @Test func aToolIsNamedOnlyByItsWholeName() {
        #expect(ToolGroup.names("edit_file", in: "Change it with `edit_file`."))
        #expect(ToolGroup.names("edit_file", in: "edit_file"))
        #expect(!ToolGroup.names("edit_file", in: "Use github_edit_file, not github_create_or_update_file."))
        #expect(!ToolGroup.names("read_file", in: "read_files and read_file_contents"))
    }

    @Test func aNameCalledWrongFindsTheFileTool() {
        var shelf = ToolShelf(groups: [group(withRepository: true)])
        // What the tool was called before, and the words the other way round.
        let earlier = shelf.nearest(to: "repo_read_file")
        let turned = shelf.nearest(to: "file_read")
        #expect(earlier?.title == "Files" && earlier?.tools == ["read_file"] && turned?.tools == ["read_file"])
        #expect(shelf.loaded == ["read_file"])
        // One word is too little to go on: it may be the web that is meant.
        let oneWord = shelf.nearest(to: "search")
        let noWord = shelf.nearest(to: "frobnicate")
        #expect(oneWord == nil && noWord == nil)
        // Every other connector's tools start with its name, so a model tries that here too.
        let prefixed = shelf.nearest(to: "files_search")
        #expect(prefixed?.tools == ["search_files"])
    }

    @Test func gitHubsOwnWaysToChangeCodeAreTheOnesLeftOut() {
        for name in ["create_pull_request", "create_branch", "create_or_update_file", "push_files", "delete_file", "edit_file"] {
            #expect(RepositoryTool.replaces("github_" + name, connector: "github"))
        }
        // What reads, what is about issues and reviews, and what another connector has, all stay.
        for name in ["github_get_file_contents", "github_list_pull_requests", "github_merge_pull_request", "github_issue_write", "linear_create_branch", "edit_file"] {
            #expect(!RepositoryTool.replaces(name, connector: "github"))
        }
    }

    @Test func aNameTakenFromGitHubIsAnsweredWithTheToolThatDoesIt() async throws {
        var shelf = ToolShelf(groups: [group(withRepository: true)])
        let unknown = shelf.redirect(for: "github_list_issues")
        #expect(unknown == nil)
        let branch = shelf.redirect(for: "github_create_branch")
        #expect(branch == "No branch is needed: repo_open_pull_request makes the branch and the commit itself.")
        // Without GitHub there is nothing to point at.
        var plain = ToolShelf(groups: [group(withRepository: false)])
        let none = plain.redirect(for: "github_open_pull_request")
        #expect(none == nil)

        // In a turn: the model edits, calls a name that is not a tool, is told the one that is, and calls that.
        let workspace = Workspace(directory: FileManager.default.temporaryDirectory.appendingPathComponent("workspace-\(UUID().uuidString)"))
        let host = FixedRepositoryHost(owner: "acme", repo: "rocket", files: ["README.md": "# Rokcet\n"])
        let provider = ScriptedProvider(turns: [
            .init(toolCalls: [ToolCall(name: "repo_clone", arguments: ["repository": "acme/rocket"])]),
            .init(toolCalls: [ToolCall(name: "edit_file", arguments: ["path": "README.md", "find": "Rokcet", "replace": "Rocket"])]),
            .init(toolCalls: [ToolCall(name: "github_open_pull_request", arguments: ["title": "Fix the title"])]),
            .init(toolCalls: [ToolCall(name: "repo_open_pull_request", arguments: ["title": "Fix the title"])]),
            .init(text: "Opened."),
        ])
        var agent = Agent(provider: provider, tools: [])
        agent.groups = [FileTool.group(workspace: workspace, repository: RepositoryCopy(workspace: workspace, host: host))]
        let events = try await collect(agent.run(messages: [.user("Fix the title of acme/rocket and open a pull request.")]))
        let results = events.toolMessages
        #expect(results.count == 4)
        #expect(results[2].isError)
        #expect(results[2].text == "There is no tool named github_open_pull_request. Use repo_open_pull_request, which opens the pull request with the changes made here.")
        #expect(!results[3].isError && host.pullRequests.count == 1 && host.pullRequests[0].files[0].text == "# Rocket\n")
    }

    @Test func textThatNamesALongerToolDoesNotLoadTheFileTool() {
        var shelf = ToolShelf(groups: [group(withRepository: false)])
        let longer = shelf.loadNamed(in: "Do not use github_edit_file for this.", request: "")
        #expect(!longer && shelf.loaded.isEmpty)
        let named = shelf.loadNamed(in: "Change the file with `edit_file`.", request: "")
        #expect(named && shelf.loaded.contains("edit_file"))
    }

    @Test func agentsSavedBeforeTheFileToolsGetThem() throws {
        func saved(tools: String, version: String) -> String {
            """
            {"id":"A0000000-0000-4000-8000-000000000009","name":"Mine","symbol":"star","summary":"","systemPrompt":"Hi",
             "tools":\(tools),"connectors":["calendar"],"thinking":"low","maxOutputTokens":2048,"isBuiltIn":false\(version)}
            """
        }
        let old = try JSONDecoder().decode(HarnessPreset.self, from: Data(saved(tools: #"["web_search"]"#, version: #","version":2"#).utf8))
        #expect(old.connectors == [.calendar, .files])
        // An agent with no tools at all is one that was meant to have none.
        let bare = try JSONDecoder().decode(HarnessPreset.self, from: Data(saved(tools: "[]", version: #","version":2"#).utf8))
        #expect(bare.connectors == [.calendar])
        // Saved since, without them: the user switched them off.
        let off = try JSONDecoder().decode(HarnessPreset.self, from: Data(saved(tools: #"["web_search"]"#, version: #","version":3"#).utf8))
        #expect(off.connectors == [.calendar])
        // And what is saved now says so.
        let again = try JSONDecoder().decode(HarnessPreset.self, from: JSONEncoder().encode(off))
        #expect(again.connectors == [.calendar])
        #expect(HarnessPreset.assistant.connectors.contains(.files) && HarnessPreset.coder.connectors == [.files] && HarnessPreset.chat.connectors.isEmpty)
    }
}

@Suite struct TarballTests {
    @Test func unpacksAnArchiveMadeByTar() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tar-\(UUID().uuidString)")
        let source = base.appendingPathComponent("acme-rocket-abc123")
        let long = "deep/" + String(repeating: "a-very-long-folder-name/", count: 6) + "file.txt"
        let big = String(repeating: "0123456789abcdef\n", count: 40000)
        for (path, text) in ["README.md": "# Rocket\n", "src/main.py": "print('hi')\n", long: "long\n", "big.txt": big, "empty.txt": ""] {
            let target = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: target)
        }
        let archive = base.appendingPathComponent("repo.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // Without this, macOS tar adds a "._" file beside each one.
        tar.environment = ["COPYFILE_DISABLE": "1"]
        tar.arguments = ["czf", archive.path, "-C", base.path, "acme-rocket-abc123"]
        try tar.run()
        tar.waitUntilExit()

        let out = base.appendingPathComponent("out")
        let counts = try Tarball.unpack(archive, into: out)
        #expect(counts.written == 5)
        #expect(try String(contentsOf: out.appendingPathComponent("src/main.py"), encoding: .utf8) == "print('hi')\n")
        #expect(try String(contentsOf: out.appendingPathComponent(long), encoding: .utf8) == "long\n")
        #expect(try String(contentsOf: out.appendingPathComponent("big.txt"), encoding: .utf8) == big)
        #expect(try Data(contentsOf: out.appendingPathComponent("empty.txt")).isEmpty)
    }
}
