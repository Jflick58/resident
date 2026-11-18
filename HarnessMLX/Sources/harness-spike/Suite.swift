import Foundation
import HarnessKit

// The eval suite: hundreds of cases kept as data in evals/cases, run through the
// same harness as the app with every outside service faked, so a run measures
// the model and the harness and nothing else. `evals/README.md` says how to run
// it and how a case is written.

/// One case: what the user says, and what must be true of what the agent then did.
struct EvalCase: Decodable {
    var id: String
    var category: String
    /// The user's messages, one per turn of the chat.
    var turns: [String]
    /// Facts the assistant already remembers about the user.
    var memory: String?
    /// Files in the files folder before the chat starts, by path.
    var files: [String: String]?
    /// Every one of these tools must run.
    var tools: [String]?
    /// At least one of these must run.
    var anyTool: [String]?
    /// No tool may run at all.
    var noTools: Bool?
    /// None of these may run.
    var forbid: [String]?
    /// No tool may run in the last turn ("Thanks!").
    var lastTurnNoTools: Bool?
    /// Each of these must appear in the arguments of some call.
    var args: [String]?
    /// One of these must appear in the arguments of some call.
    var argsAny: [String]?
    /// Each of these must appear in the final answer.
    var answer: [String]?
    /// One of these must appear in the final answer.
    var answerAny: [String]?
    /// None of these may appear in the final answer.
    var answerNot: [String]?

    /// Why the case failed, or nil when it passed. `calls` holds each turn's tool calls.
    func failure(calls: [[(name: String, arguments: String)]], answer: String) -> String? {
        let all = calls.flatMap { $0 }
        let names = Set(all.map(\.name))
        let arguments = all.map { Self.normalize($0.arguments) }.joined(separator: " ")
        let reply = Self.normalize(answer)
        if reply.isEmpty { return "no answer" }
        if noTools == true, let first = all.first { return "used \(first.name) when no tool was needed" }
        for name in tools ?? [] where !names.contains(name) { return "did not use \(name)" }
        if let anyTool, !anyTool.isEmpty, names.isDisjoint(with: anyTool) { return "did not use \(anyTool.joined(separator: " or "))" }
        for name in forbid ?? [] where names.contains(name) { return "used \(name), which it should not have" }
        if lastTurnNoTools == true, let extra = calls.last?.first { return "used \(extra.name) in the last turn" }
        for text in args ?? [] where !arguments.contains(Self.normalize(text)) { return "arguments lack \(text)" }
        if let argsAny, !argsAny.isEmpty, !argsAny.contains(where: { arguments.contains(Self.normalize($0)) }) {
            return "arguments lack \(argsAny[0])"
        }
        for text in self.answer ?? [] where !reply.contains(Self.normalize(text)) { return "answer lacks \(text)" }
        if let answerAny, !answerAny.isEmpty, !answerAny.contains(where: { reply.contains(Self.normalize($0)) }) {
            return "answer lacks \(answerAny[0])"
        }
        for text in answerNot ?? [] where reply.contains(Self.normalize(text)) { return "answer has \(text)" }
        return nil
    }

    /// Lower case, with the punctuation models vary (thousands commas, curly quotes, odd hyphens and spaces) evened out.
    static func normalize(_ text: String) -> String {
        var text = text.lowercased()
        for (from, to) in [
            (",", ""), ("\u{202F}", " "), ("\u{00A0}", " "), ("\u{2011}", "-"), ("\u{2013}", "-"), ("\u{2019}", "'"), ("\u{201C}", "\""),
            ("\u{201D}", "\""), ("**", ""), ("`", ""),
        ] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        return text
    }
}

enum EvalSuite {
    /// The repository's `evals` folder, found from where this file was compiled.
    static var folder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("evals")
    }

    /// Cases from one .jsonl file, or from every one in a folder. "all" is the repository's own.
    static func load(_ path: String) throws -> [EvalCase] {
        let url = path == "all" ? folder.appendingPathComponent("cases") : URL(fileURLWithPath: path)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            throw ProviderError("There are no eval cases at \(url.path).")
        }
        let files =
            isFolder.boolValue
            ? try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            : [url]
        var cases: [EvalCase] = []
        for file in files {
            for (number, line) in try String(contentsOf: file, encoding: .utf8).split(separator: "\n").enumerated() {
                do {
                    cases.append(try JSONDecoder().decode(EvalCase.self, from: Data(line.utf8)))
                } catch {
                    throw ProviderError("\(file.lastPathComponent) line \(number + 1) is not a case: \(error)")
                }
            }
        }
        let repeated = Dictionary(grouping: cases, by: \.id).filter { $0.value.count > 1 }.keys.sorted()
        guard repeated.isEmpty else { throw ProviderError("These case ids are used twice: \(repeated.joined(separator: ", "))") }
        return cases
    }

    /// About `count` cases, the same ones for the same seed, with every category kept in proportion.
    static func sample(_ cases: [EvalCase], count: Int, seed: Int) -> [EvalCase] {
        guard count < cases.count else { return cases }
        func rank(_ id: String) -> UInt64 {
            var hash: UInt64 = 14_695_981_039_346_656_037 &+ UInt64(truncatingIfNeeded: seed)
            for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            return hash
        }
        let share = Double(count) / Double(cases.count)
        var kept: Set<String> = []
        for group in Dictionary(grouping: cases, by: \.category).values {
            let quota = max(1, Int((Double(group.count) * share).rounded()))
            for item in group.sorted(by: { rank($0.id) < rank($1.id) }).prefix(quota) { kept.insert(item.id) }
        }
        return cases.filter { kept.contains($0.id) }
    }

    /// The range the true pass rate is likely in (95%, Wilson), as whole percentages.
    static func interval(passed: Int, of total: Int) -> (low: Int, high: Int) {
        guard total > 0 else { return (0, 0) }
        let n = Double(total)
        let p = Double(passed) / n
        let z = 1.96
        let centre = (p + z * z / (2 * n)) / (1 + z * z / n)
        let spread = z * (p * (1 - p) / n + z * z / (4 * n * n)).squareRoot() / (1 + z * z / n)
        return (Int((max(0, centre - spread) * 100).rounded()), Int((min(1, centre + spread) * 100).rounded()))
    }

    /// Ids already in a results file for this model and label, so a stopped run can carry on.
    static func finished(in path: String, model: String, label: String) -> Set<String> {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var ids: Set<String> = []
        for line in text.split(separator: "\n") {
            guard let value = JSONValue(jsonString: String(line)), value["model"]?.stringValue == model,
                value["label"]?.stringValue == label, let id = value["id"]?.stringValue
            else { continue }
            ids.insert(id)
        }
        return ids
    }

    static func append(_ line: JSONValue, to path: String) {
        let data = Data((line.jsonString + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// A tool with its real name, description and parameters, answering from fixed data.
struct FixtureTool: Tool {
    var base: any Tool
    var answer: @Sendable (JSONValue) -> ToolResult

    var spec: ToolSpec { base.spec }
    func summary(for arguments: JSONValue) -> String { base.summary(for: arguments) }
    func call(_ arguments: JSONValue) async -> ToolResult { answer(arguments) }
}

/// The web as the suite sees it: made-up search results and pages from evals/web.json.
///
/// The facts in it are invented, so a model cannot answer from what it knows, and
/// a run does not depend on the network or on what a search engine returns today.
struct WebFixtures: Decodable {
    struct Rule: Decodable {
        /// Words that must all be in the query.
        var match: [String]
        var results: [Result]
    }
    struct Result: Decodable {
        var title: String
        var url: String
        var snippet: String
    }
    var search: [Rule]
    var pages: [String: String]

    static func load() -> WebFixtures {
        let url = EvalSuite.folder.appendingPathComponent("web.json")
        guard let data = try? Data(contentsOf: url), let fixtures = try? JSONDecoder().decode(WebFixtures.self, from: data) else {
            print("Could not read \(url.path)")
            exit(2)
        }
        return fixtures
    }

    private static func key(_ address: String) -> String {
        var text = address.lowercased().trimmingCharacters(in: .whitespaces)
        for prefix in ["https://", "http://", "www."] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    func searchTool() -> FixtureTool {
        FixtureTool(base: WebSearchTool()) { arguments in
            let query = (arguments["query"]?.stringValue ?? "").lowercased()
            guard !query.isEmpty else { return .error("Missing required argument: query.") }
            // The rule with the most words wins, so a narrow rule beats a broad one.
            let rule = search.filter { $0.match.allSatisfy { query.contains($0.lowercased()) } }.max { $0.match.count < $1.match.count }
            guard let rule else { return ToolResult("No results for “\(query)”. Try different keywords.") }
            return ToolResult(
                rule.results.enumerated().map { "\($0 + 1). \($1.title)\n   \($1.url)\n   \($1.snippet)" }.joined(separator: "\n"))
        }
    }

    func fetchTool() -> FixtureTool {
        let byKey = Dictionary(pages.map { (Self.key($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        return FixtureTool(base: FetchPageTool()) { arguments in
            guard let address = arguments["url"]?.stringValue, !address.isEmpty else { return .error("Missing required argument: url.") }
            guard let text = byKey[Self.key(address)] else { return .error("Could not load the page: the server answered 404.") }
            return ToolResult(text)
        }
    }
}
