import Foundation
import Testing

@testable import HarnessKit

struct StubFetcher: HTTPFetching {
    var body: String
    var status = 200
    var contentType = "text/html; charset=utf-8"

    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": contentType])!
        return (Data(body.utf8), response)
    }
}

@Suite struct JavaScriptToolTests {
    @Test func returnsLastExpression() async {
        let result = await JavaScriptTool().call(["code": "2 + 2 * 10"])
        #expect(result.text == "=> 22")
        #expect(!result.isError)
    }

    @Test func capturesConsoleOutput() async {
        let result = await JavaScriptTool().call(["code": "console.log('a', 1, {b: 2}); [1,2,3].map(x => x * 2)"])
        #expect(result.text == "a 1 {\"b\":2}\n=> [2,4,6]")
    }

    @Test func reportsExceptions() async {
        let result = await JavaScriptTool().call(["code": "nope()"])
        #expect(result.isError)
        #expect(result.text.contains("ReferenceError"))
    }

    @Test func stopsRunawayCode() async {
        let started = Date()
        let result = await JavaScriptTool(timeout: 0.5).call(["code": "while (true) {}"])
        #expect(result.isError)
        #expect(result.text.contains("stopped"))
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func hasNoNetworkAccess() async {
        let result = await JavaScriptTool().call(["code": "typeof fetch + ' ' + typeof XMLHttpRequest"])
        #expect(result.text == "=> undefined undefined")
    }

    @Test func missingCodeIsAnError() async {
        #expect(await JavaScriptTool().call([:]).isError)
    }
}

@Suite struct WebToolTests {
    static let resultsPage = """
        <div class="result results_links results_links_deep web-result">
          <h2 class="result__title">
            <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.swift.org%2Fblog%2F&amp;rut=abc">Swift.org &amp; <b>Blog</b></a>
          </h2>
          <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.swift.org%2Fblog%2F">News about the <b>Swift</b> language.</a>
        </div>
        <div class="result results_links web-result">
          <a class="result__a" href="https://example.com/direct">Direct link</a>
          <a class="result__snippet" href="https://example.com/direct">Second snippet.</a>
        </div>
        """

    @Test func parsesSearchResults() {
        let results = WebSearchTool.parseResults(Self.resultsPage)
        #expect(results.count == 2)
        #expect(results[0].title == "Swift.org & Blog")
        #expect(results[0].url == "https://www.swift.org/blog/")
        #expect(results[0].snippet == "News about the Swift language.")
        #expect(results[1].url == "https://example.com/direct")
    }

    @Test func searchToolFormatsResults() async {
        let tool = WebSearchTool(fetcher: StubFetcher(body: Self.resultsPage))
        let result = await tool.call(["query": "swift"])
        #expect(result.text.hasPrefix("1. Swift.org & Blog\n   https://www.swift.org/blog/"))
        #expect(tool.summary(for: ["query": "swift"]) == "Searched the web for “swift”")
    }

    @Test func searchReportsNoResults() async {
        let result = await WebSearchTool(fetcher: StubFetcher(body: "<html></html>")).call(["query": "zzz"])
        #expect(result.text.contains("No results"))
    }

    @Test func fetchPageExtractsReadableText() async {
        let html = """
            <html><head><title>Test &amp; Page</title><style>p{color:red}</style></head>
            <body><nav>Menu Home About</nav><script>var x = 1;</script>
            <p>First paragraph with enough words to count as real readable content here.</p>
            <ul><li>One</li><li>Two</li></ul><footer>Copyright</footer></body></html>
            """
        let result = await FetchPageTool(fetcher: StubFetcher(body: html)).call(["url": "example.com/a"])
        #expect(!result.isError)
        #expect(result.text.hasPrefix("# Test & Page\n"))
        #expect(result.text.contains("First paragraph"))
        #expect(result.text.contains("- One"))
        #expect(!result.text.contains("Menu"))
        #expect(!result.text.contains("var x"))
        #expect(!result.text.contains("Copyright"))
    }

    @Test func fetchPageRejectsBadInput() async {
        let tool = FetchPageTool(fetcher: StubFetcher(body: ""))
        #expect(await tool.call(["url": "file:///etc/passwd"]).isError)
        #expect(await tool.call([:]).isError)
        let missing = FetchPageTool(fetcher: StubFetcher(body: "gone", status: 404))
        #expect(await missing.call(["url": "https://example.com"]).text.contains("404"))
    }

    @Test func fetchPagePicksRelevantPassages() async {
        var paragraphs: [String] = []
        for index in 0..<60 {
            paragraphs.append("<p>Filler paragraph number \(index) about gardening, soil and weather across many seasons of the year in detail.</p>")
        }
        paragraphs.insert("<p>The capital of Australia is Canberra, chosen in 1908 as a compromise between Sydney and Melbourne.</p>", at: 45)
        let html = "<html><body>" + paragraphs.joined() + "</body></html>"
        let tool = FetchPageTool(fetcher: StubFetcher(body: html), maxCharacters: 800)
        let result = await tool.call(["url": "https://example.com", "question": "capital of Australia"])
        #expect(result.text.contains("Canberra"))
        #expect(result.text.count < 1000)
    }
}

@Suite struct MemoryTests {
    func makeStore(max: Int = 2000) -> MemoryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-tests-\(UUID().uuidString)/memory.md")
        return MemoryStore(url: url, maxCharacters: max)
    }

    @Test func savesAndDeduplicates() async {
        let store = makeStore()
        let tool = SaveMemoryTool(store: store)
        #expect(await tool.call(["fact": "Prefers metric units"]).text == "Saved.")
        #expect(await tool.call(["fact": "prefers metric units"]).text == "Already saved.")
        #expect(store.facts == ["Prefers metric units"])
        #expect(store.text == "- Prefers metric units")
    }

    @Test func refusesWhenFull() async {
        let store = makeStore(max: 30)
        let tool = SaveMemoryTool(store: store)
        _ = await tool.call(["fact": "Short fact one"])
        #expect(await tool.call(["fact": "A second fact that is too long"]).isError)
        #expect(store.facts.count == 1)
    }
}

@Suite struct ThinkTagSplitterTests {
    @Test func splitsAcrossChunkBoundaries() {
        var splitter = ThinkTagSplitter()
        var pieces: [ThinkTagSplitter.Piece] = []
        for chunk in ["<thi", "nk>plan", "ning</th", "ink>Ans", "wer"] {
            pieces += splitter.feed(chunk)
        }
        pieces += splitter.finish()
        let reasoning = pieces.compactMap { if case .reasoning(let t) = $0 { return t } else { return nil } }.joined()
        let text = pieces.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        #expect(reasoning == "planning")
        #expect(text == "Answer")
    }

    @Test func passesPlainTextThrough() {
        var splitter = ThinkTagSplitter()
        let pieces = splitter.feed("a < b and x") + splitter.finish()
        #expect(pieces == [.text("a < b and x")])
    }
}

@Suite struct OpenAIStreamParserTests {
    /// A model that cannot stop thinking sends it in the answer, with only the end marked.
    @Test func thinkingLeakedIntoAHeldAnswerIsTakenOut() {
        var parser = OpenAICompatibleProvider.StreamParser(holdsText: true)
        var events: [ProviderEvent] = []
        events += parser.consume(line: #"data: {"choices":[{"delta":{"content":"Okay, the user wants a capital. "}}]}"#)
        #expect(events.isEmpty)
        events += parser.consume(line: #"data: {"choices":[{"delta":{"content":"It is Canberra.\n</think>\n\nCanberra"},"finish_reason":"stop"}]}"#)
        events += parser.finish()
        var text = ""
        var reasoning = ""
        for event in events {
            if case .text(let value) = event { text += value }
            if case .reasoning(let value) = event { reasoning += value }
        }
        #expect(text == "Canberra")
        #expect(reasoning == "Okay, the user wants a capital. It is Canberra.")
        #expect(parser.leakedThinking)

        var clean = OpenAICompatibleProvider.StreamParser(holdsText: true)
        _ = clean.consume(line: #"data: {"choices":[{"delta":{"content":"Canberra"},"finish_reason":"stop"}]}"#)
        let kept = clean.finish()
        #expect(!clean.leakedThinking)
        #expect(kept.contains { if case .text("Canberra") = $0 { return true } else { return false } })
    }

    @Test func parsesTextReasoningAndUsage() {
        var parser = OpenAICompatibleProvider.StreamParser()
        var events: [ProviderEvent] = []
        events += parser.consume(line: #"data: {"choices":[{"delta":{"reasoning_content":"think"}}]}"#)
        events += parser.consume(line: #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#)
        events += parser.consume(line: #"data: {"choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}"#)
        events += parser.consume(line: #"data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2}}"#)
        events += parser.consume(line: "data: [DONE]")
        events += parser.finish()

        var text = ""
        var reasoning = ""
        var final: (StopReason, GenerationStats?)?
        for event in events {
            switch event {
            case .text(let value): text += value
            case .reasoning(let value): reasoning += value
            case .finished(let reason, let stats): final = (reason, stats)
            case .toolCall: Issue.record("unexpected tool call")
            }
        }
        #expect(text == "Hello")
        #expect(reasoning == "think")
        #expect(final?.0 == .stop)
        #expect(final?.1?.outputTokens == 2)
    }

    @Test func assemblesStreamedToolCalls() {
        var parser = OpenAICompatibleProvider.StreamParser()
        _ = parser.consume(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"web_search","arguments":""}}]}}]}"#)
        _ = parser.consume(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"query\":"}}]}}]}"#)
        _ = parser.consume(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"swift\"}"}}]},"finish_reason":"tool_calls"}]}"#)
        let events = parser.finish()
        guard case .toolCall(let call) = events.first else {
            Issue.record("expected a tool call")
            return
        }
        #expect(call.id == "call_1")
        #expect(call.name == "web_search")
        #expect(call.arguments == ["query": "swift"])
        guard case .finished(let reason, _) = events.last else {
            Issue.record("expected finish")
            return
        }
        #expect(reason == .toolCalls)
    }

    @Test func encodesToolRoundTrip() {
        let call = ToolCall(id: "c1", name: "echo", arguments: ["text": "a"])
        let request = GenerationRequest(
            messages: [.system("s"), .user("u"), .assistant("", toolCalls: [call]), .tool("r", call: call)],
            tools: [EchoTool().spec], options: .init(maxOutputTokens: 100, temperature: 0, thinking: .off))
        let body = OpenAICompatibleProvider.requestBody(request, model: "m", thinkingStyle: .reasoningEffort)
        #expect(OpenAICompatibleProvider.requestBody(request, model: "m", thinkingStyle: .thinkFlag)["think"] == false)
        #expect(body["messages"]?.arrayValue?.count == 4)
        #expect(body["messages"]?.arrayValue?[2]["tool_calls"]?.arrayValue?.first?["function"]?["arguments"] == .string(#"{"text":"a"}"#))
        #expect(body["messages"]?.arrayValue?[3]["tool_call_id"] == "c1")
        #expect(body["tools"]?.arrayValue?.first?["function"]?["name"] == "echo")
        #expect(body["reasoning_effort"] == "none")
        #expect(body["max_tokens"] == 100)  // thinking off adds no allowance
    }
}

@Suite struct PageTextTests {
    @Test func scoreboardFragmentsBecomeRows() {
        let html = """
            <html><body><div>49ers</div><div>SF</div><div><span>7</span> <span>10</span> <span>14</span> <span>15</span> <span>46</span></div>
            <div>Cowboys</div><div>DAL</div><div>10 6 3 21 40</div><div>DAL</div><div>DAL</div>
            <p>Dak Prescott threw a late touchdown pass to CeeDee Lamb to bring the Cowboys within six.</p>
            <ul><li>First item</li><li>Second item</li></ul></body></html>
            """
        let lines = HTMLText.plainText(from: html).components(separatedBy: "\n")
        #expect(lines[0] == "49ers · SF · 7 10 14 15 46 · Cowboys · DAL · 10 6 3 21 40 · DAL")
        #expect(lines[1].hasPrefix("Dak Prescott threw"))
        #expect(lines[2] == "- First item")
        #expect(lines[3] == "- Second item")
    }
}

@Suite struct SamplingTests {
    @Test func readsTheMakersSettings() {
        let config: JSONValue = ["do_sample": true, "temperature": 0.1, "repetition_penalty": 1.1, "top_k": 50]
        let sampling = SamplingSettings(generationConfig: config)
        #expect(sampling == SamplingSettings(temperature: 0.1, topP: 0.95, repetitionPenalty: 1.1))
        #expect(SamplingSettings(generationConfig: nil) == .standard)
        #expect(SamplingSettings(generationConfig: ["do_sample": false, "temperature": 0.1]) == .standard)
    }

    @Test func agentTemperatureWinsOverTheModels() throws {
        var agent = HarnessPreset.assistant
        let model = SamplingSettings(temperature: 0.1, topP: 0.9, repetitionPenalty: 1.1)
        #expect(agent.options(sampling: model).temperature == 0.1)
        agent.temperature = 1.0
        #expect(agent.options(sampling: model).temperature == 1.0)
        // A preset saved before agents could leave temperature to the model: 0.6 meant no preference.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(agent)) as! [String: Any]
        old["version"] = nil
        old["temperature"] = 0.6
        let decoded = try JSONDecoder().decode(HarnessPreset.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.temperature == nil)
        old["temperature"] = 0.2
        #expect(try JSONDecoder().decode(HarnessPreset.self, from: JSONSerialization.data(withJSONObject: old)).temperature == 0.2)
        let options = agent.options(sampling: model, thinking: .high)
        #expect(options.topP == 0.9 && options.repetitionPenalty == 1.1 && options.thinking == .high)
    }
}

@Suite struct ResultFitTests {
    private func issues(_ count: Int) -> String {
        let items: [JSONValue] = (1...count).map { index in
            [
                "description": .string(String(repeating: "A long description of the work. ", count: 40)),
                "id": .string("ENG-\(index)"), "title": .string("Issue number \(index)"), "labels": [], "dueDate": .null,
                "assignee": ["name": "Sam"],
            ]
        }
        return JSONValue.object(["issues": .array(items), "hasNextPage": true]).jsonString
    }

    @Test func shortTextIsLeftAlone() {
        #expect(ResultFit.fit("hello", limit: 100) == "hello")
    }

    @Test func longFieldsAreShortenedBeforeItemsAreDropped() {
        let fitted = ResultFit.fit(issues(20), limit: 6000)
        #expect(fitted.count <= 6000)
        // Every issue is still there, each led by what identifies it.
        #expect(fitted.contains(#"{"id":"ENG-20","title":"Issue number 20""#))
        #expect(!fitted.contains("labels") && !fitted.contains("dueDate"))
        #expect(fitted.contains("Long text was shortened"))
    }

    @Test func itemsThatDoNotFitAreCountedNotSilentlyLost() {
        let fitted = ResultFit.fit(issues(200), limit: 6000)
        #expect(fitted.count <= 6000)
        #expect(fitted.contains("of 200 items"))
        #expect(fitted.contains(#""id":"ENG-1""#))
        #expect(fitted.contains(#""hasNextPage":true"#))
    }

    @Test func plainTextIsCutWithANote() {
        let fitted = ResultFit.fit(String(repeating: "word ", count: 5000), limit: 1000)
        #expect(fitted.hasPrefix("word word") && fitted.contains("cut off at 1000"))
    }
}

@Suite struct HousekeepingTests {
    @Test func onlyMessagesAboutOneselfGetAMemoryPass() {
        #expect(Housekeeping.mightHoldAFact("I just moved to Sacramento, any dinner ideas?"))
        #expect(!Housekeeping.mightHoldAFact("What is the capital of Australia?"))
        #expect(!Housekeeping.mightHoldAFact("Thanks, I see"))
    }

    @Test func keepsFactsTheMessageStatesAndNothingElse() {
        let reply = """
            - The user has a peanut allergy.
            - The user is allergic to shellfish.
            - The user wants to know if pad thai is safe.
            - The user is allergic to peanuts (important).
            Some other line
            """
        let update = Housekeeping.parseMemoryUpdate(reply, known: [], message: "I have a peanut allergy, is pad thai safe?")
        #expect(update.facts == ["The user has a peanut allergy."])
        #expect(Housekeeping.parseMemoryUpdate("NONE", known: [], message: "I have a cat").isEmpty)
    }

    @Test func aFactThatTurnsAnOldOneRoundReplacesIt() {
        let reply = "- The user is not vegetarian and now eats fish.\n- The user is no longer vegetarian; they eat fish."
        let update = Housekeeping.parseMemoryUpdate(
            reply, known: ["The user is vegetarian.", "The user lives in Sacramento."],
            message: "Actually I'm not vegetarian any more, I eat fish now.")
        #expect(update.facts == ["The user is not vegetarian and now eats fish."])
        #expect(update.forget == ["The user is vegetarian."])
        // Already known: nothing to add.
        let again = Housekeeping.parseMemoryUpdate(
            "- The user lives in Sacramento.", known: ["The user lives in Sacramento."], message: "I live in Sacramento, as you know.")
        #expect(again.isEmpty)
    }

    @Test func titlesAreShortAndPlain() {
        #expect(Housekeeping.cleanTitle("\"Open Linear Tickets.\"") == "Open Linear Tickets")
        #expect(Housekeeping.cleanTitle("Title: Dinner ideas") == "Dinner ideas")
        #expect(Housekeeping.cleanTitle("Here is a long explanation of what this conversation was about and why") == nil)
    }
}

@Suite struct SaveSkillToolTests {
    @Test func savesOnlyWhatTheUserApproves() async {
        let arguments: JSONValue = [
            "name": "Standup Update", "when": "Writing my daily standup",
            "instructions": "1. Yesterday in one bullet.\n2. Today in one bullet.\n3. Blockers, or none.",
        ]
        let approved = await SaveSkillTool { skill in
            #expect(skill.name == "standup-update" && skill.summary == "Writing my daily standup")
            return skill
        }.call(arguments)
        #expect(!approved.isError && approved.text.contains("Saved the skill standup-update"))

        let declined = await SaveSkillTool { _ in nil }.call(arguments)
        #expect(!declined.isError && declined.text.contains("chose not to save"))

        let thin = await SaveSkillTool { $0 }.call(["name": "x", "when": "y", "instructions": "do it"])
        #expect(thin.isError)
    }
}

@Suite struct UpdateSkillToolTests {
    private let old = Skill(name: "open-tickets", summary: "Listing my tickets", instructions: "1. List the issues.\n2. Leave out closed ones.")

    @Test func addsToASkillAndKeepsTheRest() async {
        let result = await UpdateSkillTool(skills: [old]) { skill in
            #expect(skill.id == old.id && skill.summary == old.summary)
            #expect(skill.instructions == "1. List the issues.\n2. Leave out closed ones.\n3. To close one, set its state to Done.")
            return skill
        }.call(["name": "open-tickets", "add": "3. To close one, set its state to Done."])
        #expect(!result.isError && result.text.contains("Updated the skill open-tickets"))
    }

    @Test func replacesTextThatIsThere() async {
        let result = await UpdateSkillTool(skills: [old]) { skill in
            #expect(skill.instructions == "1. List the issues.\n2. Leave out done ones.")
            return skill
        }.call(["name": "open-tickets", "remove": "closed ones", "add": "done ones"])
        #expect(!result.isError)
        let missing = await UpdateSkillTool(skills: [old]) { $0 }.call(["name": "open-tickets", "remove": "not there", "add": "x"])
        #expect(missing.isError && missing.text.contains("1. List the issues."))
    }

    @Test func aNewSkillUnderAnOldNameIsSentToUpdate() async {
        let result = await SaveSkillTool(existing: [old]) { $0 }.call([
            "name": "open-tickets", "when": "Listing my tickets", "instructions": "1. List the issues and nothing more.",
        ])
        #expect(result.isError && result.text.contains("update_skill"))
        let unknown = await UpdateSkillTool(skills: [old]) { $0 }.call(["name": "nothing", "add": "A step to add."])
        #expect(unknown.isError)
    }
}

@Suite struct SkillDraftTests {
    @Test func readsADraftInTheAskedForm() throws {
        let reply = """
            NAME: Latest Versions
            WHEN: The user asks for the newest version of a programming language
            STEPS:
            1. Search the web for the language's releases with web_search.
            2. Open the official release page with fetch_page.
            3. web_search {"query":"copied call"}
            4. Answer with the version and its date in one line.
            """
        let skill = try #require(Housekeeping.parseSkillDraft(reply))
        #expect(skill.name == "latest-versions")
        #expect(skill.summary.hasPrefix("The user asks for the newest version"))
        #expect(skill.instructions.components(separatedBy: "\n").count == 3)
        #expect(Housekeeping.parseSkillDraft("I could not write one.") == nil)
    }
}

@Suite struct GreetingTests {
    private func date(hour: Int) -> (Date, Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return (calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: hour))!, calendar)
    }

    @Test func followsTheTimeOfDay() {
        let (morning, calendar) = date(hour: 8)
        #expect(Greeting.line(name: "Sam", date: morning, calendar: calendar) == "Good morning, Sam")
        #expect(Greeting.line(date: date(hour: 19).0, calendar: calendar) == "Good evening")
        #expect(Greeting.invitation(date: morning, calendar: calendar).hasSuffix("?"))
        #expect(["Up late, Sam?", "Still up, Sam?"].contains(Greeting.line(name: "Sam", date: date(hour: 1).0, calendar: calendar)))
    }

    @Test func findsTheUsersOwnName() {
        #expect(Greeting.name(in: ["The user lives in Sacramento.", "The user's name is Justin."]) == "Justin")
        #expect(Greeting.name(in: ["The user goes by JJ."]) == "JJ")
        #expect(Greeting.name(in: ["The user's daughter's name is Nedra."]) == nil)
        #expect(Greeting.name(in: ["The user is vegetarian."]) == nil)
    }
}

@Suite struct FileEditToolTests {
    /// A repository of one file, behind tools shaped like GitHub's.
    final class Repo: @unchecked Sendable {
        var text = "# Rokcet\n\nFuel tools.\nFuel tools.\n\n    python -m rocket\n"
        var saved: JSONValue?
    }
    struct Read: Tool {
        var repo: Repo
        var spec: ToolSpec { ToolSpec(name: "github_get_file_contents", description: "Read", parameters: ["type": "object"]) }
        func call(_ arguments: JSONValue) async -> ToolResult {
            arguments["path"]?.stringValue == "README.md"
                ? ToolResult("successfully downloaded text file (SHA: a41c0de)\n" + repo.text) : .error("path was not found.")
        }
    }
    struct Write: Tool {
        var repo: Repo
        var spec: ToolSpec { ToolSpec(name: "github_create_or_update_file", description: "Write", parameters: ["type": "object"]) }
        func call(_ arguments: JSONValue) async -> ToolResult {
            repo.saved = arguments
            return ToolResult("ok")
        }
    }

    func tool(_ repo: Repo) throws -> any Tool {
        let tools = FileEditTool.adding(to: [Read(repo: repo), Write(repo: repo)], title: "GitHub")
        return try #require(tools.first { $0.spec.name == "github_edit_file" })
    }

    func arguments(find: String, replace: String, path: String = "README.md") -> JSONValue {
        ["owner": "acme", "repo": "rocket", "path": .string(path), "branch": "fix", "find": .string(find), "replace": .string(replace), "message": "Fix"]
    }

    @Test func isAddedOnlyWhereItCanWork() {
        let repo = Repo()
        #expect(FileEditTool.adding(to: [Read(repo: repo)], title: "GitHub").count == 1)
        #expect(FileEditTool.adding(to: [EchoTool()], title: "Other").count == 1)
        #expect(FileEditTool.adding(to: [Read(repo: repo), Write(repo: repo)], title: "GitHub").count == 3)
    }

    @Test func changesOnlyTheTextItWasGiven() async throws {
        let repo = Repo()
        let result = try await tool(repo).call(arguments(find: "# Rokcet", replace: "# Rocket"))
        #expect(!result.isError)
        #expect(repo.saved?["content"]?.stringValue == "# Rocket\n\nFuel tools.\nFuel tools.\n\n    python -m rocket\n")
        #expect(repo.saved?["sha"]?.stringValue == "a41c0de")
        #expect(repo.saved?["branch"]?.stringValue == "fix")
    }

    @Test func forgivesSpaceAroundTheText() async throws {
        let repo = Repo()
        let result = try await tool(repo).call(arguments(find: "\n# Rokcet \n", replace: "# Rocket"))
        #expect(!result.isError)
        #expect(repo.saved?["content"]?.stringValue?.hasPrefix("# Rocket\n\nFuel") == true)
    }

    @Test func refusesTextThatIsMissingOrRepeated() async throws {
        let repo = Repo()
        let missing = try await tool(repo).call(arguments(find: "python -m rocket --fast", replace: "x"))
        #expect(missing.isError)
        #expect(missing.text.contains("python -m rocket"))
        let repeated = try await tool(repo).call(arguments(find: "Fuel tools.", replace: "x"))
        #expect(repeated.isError)
        #expect(repeated.text.contains("2 times"))
        let absent = try await tool(repo).call(arguments(find: "a", replace: "b", path: "nope.md"))
        #expect(absent.isError)
        #expect(repo.saved == nil)
    }
}
