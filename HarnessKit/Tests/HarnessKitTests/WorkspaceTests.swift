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

    func make() -> (Workspace, FixedRepositoryHost, [String: any Tool]) {
        let host = FixedRepositoryHost(
            owner: "acme", repo: "rocket",
            files: [
                "README.md": "# Rokcet\n\nFuel tools.\n", "web/styles.css": "body {\n  margin: 0;\n  background: #ffffff;\n}\n",
                "src/gauge.py": "OFFSET = 12\n\n\ndef read_fuel_level(sensor):\n    return sensor.raw - OFFSET\n", "docs/GUIDE.md": Self.guide,
            ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-\(UUID().uuidString)")
        let workspace = Workspace(directory: directory, host: host)
        let tools = Dictionary(uniqueKeysWithValues: RepoTool.group(workspace: workspace).tools.map { ($0.spec.name, $0) })
        return (workspace, host, tools)
    }

    @Test func nothingWorksBeforeAClone() async {
        let (_, _, tools) = make()
        let result = await tools["repo_read_file"]!.call(["path": "README.md"])
        #expect(result.isError && result.text.contains("repo_clone"))
    }

    @Test func cloneListsTheFiles() async {
        let (_, _, tools) = make()
        let result = await tools["repo_clone"]!.call(["repository": "https://github.com/acme/rocket"])
        #expect(!result.isError)
        #expect(result.text.contains("web/styles.css") && result.text.contains("4 files"))
        let missing = await tools["repo_clone"]!.call(["repository": "acme/other"])
        #expect(missing.isError)
    }

    @Test func cloneTakesOwnerAndRepoApart() async {
        let (_, _, tools) = make()
        let result = await tools["repo_clone"]!.call(["owner": "acme", "repo": "rocket"])
        #expect(!result.isError)
    }

    @Test func searchFindsLinesAndFileNames() async {
        let (_, _, tools) = make()
        _ = await tools["repo_clone"]!.call(["repository": "acme/rocket"])
        let lines = await tools["repo_search"]!.call(["query": "BACKGROUND"])
        #expect(lines.text == "web/styles.css:3: background: #ffffff;")
        let pattern = await tools["repo_search"]!.call(["query": "bg|background|colou?r"])
        #expect(pattern.text.contains("web/styles.css:3"))
        let name = await tools["repo_search"]!.call(["query": "readme"])
        #expect(name.text.contains("README.md  (the file's name matches)"))
        let many = await tools["repo_search"]!.call(["query": "gauge", "path": "docs"])
        #expect(many.text.contains("400 matches in 1 files"))
        let nothing = await tools["repo_search"]!.call(["query": "zebra"])
        #expect(!nothing.isError && nothing.text.contains("Nothing"))
    }

    @Test func readGivesALongFileInParts() async {
        let (_, _, tools) = make()
        _ = await tools["repo_clone"]!.call(["repository": "acme/rocket"])
        let first = await tools["repo_read_file"]!.call(["path": "docs/GUIDE.md"])
        #expect(first.text.hasPrefix("Step 1: check the gauge."))
        #expect(first.text.contains("call repo_read_file again with start_line"))
        #expect(first.text.count < 6000)
        let last = await tools["repo_read_file"]!.call(["path": "docs/GUIDE.md", "start_line": 395])
        #expect(last.text.hasPrefix("Step 395") && last.text.contains("Lines 395 to 400 of 400") && last.text.contains("end of the file"))
    }

    @Test func aGuessedPathIsCorrected() async {
        let (_, _, tools) = make()
        _ = await tools["repo_clone"]!.call(["repository": "acme/rocket"])
        let result = await tools["repo_read_file"]!.call(["path": "styles.css"])
        #expect(result.isError && result.text.contains("Did you mean: web/styles.css?"))
        let outside = await tools["repo_read_file"]!.call(["path": "../../etc/passwd"])
        #expect(outside.isError)
    }

    @Test func editThenPullRequestSendsTheWholeChangedFile() async {
        let (_, host, tools) = make()
        _ = await tools["repo_clone"]!.call(["repository": "acme/rocket"])
        let none = await tools["repo_open_pull_request"]!.call(["title": "Pink"])
        #expect(none.isError && none.text.contains("repo_edit_file"))

        let edit = await tools["repo_edit_file"]!.call(["path": "web/styles.css", "find": "background: #ffffff;", "replace": "background: pink;"])
        #expect(!edit.isError && edit.text.contains("From line 3 it now reads:\n  background: pink;"))
        let opened = await tools["repo_open_pull_request"]!.call(["title": "Make the page background pink", "body": "As asked."])
        #expect(opened.text.contains("https://github.com/acme/rocket/pull/42"))
        let draft = host.pullRequests[0]
        #expect(draft.base == "main" && draft.commit == "c0ffee0" && draft.branch == "make-the-page-background-pink")
        #expect(draft.files.count == 1 && draft.files[0].path == "web/styles.css")
        #expect(draft.files[0].text == "body {\n  margin: 0;\n  background: pink;\n}\n")

        let again = await tools["repo_open_pull_request"]!.call(["title": "Pink"])
        #expect(again.isError)
    }

    @Test func cloningAgainKeepsFreshChanges() async {
        let (_, _, tools) = make()
        _ = await tools["repo_clone"]!.call(["repository": "acme/rocket"])
        _ = await tools["repo_edit_file"]!.call(["path": "README.md", "find": "Rokcet", "replace": "Rocket"])
        let again = await tools["repo_clone"]!.call(["repository": "acme/rocket"])
        #expect(again.text.contains("already cloned") && again.text.contains("README.md"))
        let read = await tools["repo_read_file"]!.call(["path": "README.md"])
        #expect(read.text.hasPrefix("# Rocket"))
    }

    @Test func writeMakesNewFilesAndWillNotShortenLongOnes() async {
        let (_, host, tools) = make()
        _ = await tools["repo_clone"]!.call(["repository": "acme/rocket"])
        let new = await tools["repo_write_file"]!.call(["path": "docs/NOTES.md", "content": "# Notes\n"])
        #expect(!new.isError)
        let short = await tools["repo_write_file"]!.call(["path": "docs/GUIDE.md", "content": "Step 1: check the gauge.\n"])
        #expect(short.isError && short.text.contains("repo_edit_file"))
        _ = await tools["repo_open_pull_request"]!.call(["title": "Add notes"])
        #expect(host.pullRequests[0].files.map(\.path) == ["docs/NOTES.md"])
    }

    @Test func stateOutlastsTheProcess() async {
        let host = FixedRepositoryHost(owner: "acme", repo: "rocket", files: ["README.md": "# Rokcet\n"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-\(UUID().uuidString)")
        let first = Workspace(directory: directory, host: host)
        _ = await first.clone("acme/rocket")
        _ = await first.edit("README.md", find: "Rokcet", replace: "Rocket")
        let second = Workspace(directory: directory, host: host)
        let opened = await second.openPullRequest(title: "Fix the title", body: "")
        #expect(!opened.isError && host.pullRequests[0].files[0].text == "# Rocket\n")
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
