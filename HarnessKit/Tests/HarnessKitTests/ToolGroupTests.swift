import Foundation
import Testing

@testable import HarnessKit

private struct NamedTool: Tool {
    var name: String
    var description: String
    var fails = false
    var spec: ToolSpec {
        ToolSpec(
            name: name, description: description,
            parameters: ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]])
    }
    func call(_ arguments: JSONValue) async -> ToolResult { fails ? .error("id is missing") : ToolResult("ran \(name)") }
}

/// A connector the size of Linear's.
private func bigGroup() -> ToolGroup {
    let names = [
        "list_issues": "List issues in the workspace, filtered by assignee, team or state",
        "get_issue": "Get one issue by its identifier", "save_issue": "Create or update an issue",
        "list_comments": "List the comments on an issue", "save_comment": "Add a comment to an issue",
        "list_projects": "List projects", "get_project": "Get one project", "save_project": "Create or update a project",
        "list_teams": "List teams", "get_team": "Get one team", "list_users": "List people in the workspace",
        "get_user": "Get one person", "list_cycles": "List a team's cycles", "list_documents": "List documents",
        "get_document": "Get one document", "save_document": "Create or update a document",
        "list_issue_labels": "List labels that can be put on issues", "create_issue_label": "Create a label",
        "list_issue_statuses": "List the workflow states of a team", "get_issue_status": "Get one workflow state",
        "list_milestones": "List the milestones of a project", "save_milestone": "Create or update a milestone",
        "get_status_updates": "Get status updates for a project", "save_status_update": "Post a status update",
        "search_documentation": "Search the product's help pages", "list_releases": "List releases",
        "get_release": "Get one release",
    ]
    return ToolGroup(
        name: "linear", title: "Linear", summary: "Issues and projects",
        tools: names.sorted { $0.key < $1.key }.map { NamedTool(name: "linear_" + $0.key, description: $0.value) })
}

private func smallGroup() -> ToolGroup {
    ToolGroup(
        name: "deepwiki", title: "DeepWiki",
        tools: ["read_wiki", "ask_question"].map { NamedTool(name: "deepwiki_" + $0, description: "About a repository", fails: true) })
}

@Suite struct ToolGroupTests {
    @Test func picksToolsThatFitTheNeed() {
        let picked = bigGroup().pick("add a comment to the issue").map(\.spec.name)
        #expect(picked.count == ToolGroup.perOpen)
        #expect(picked.contains("linear_save_comment"))
        #expect(picked.contains("linear_list_comments"))
    }

    @Test func smallConnectorComesWhole() {
        #expect(smallGroup().pick("anything").count == 2)
    }

    @Test func promptShowsOneLinePerConnector() throws {
        let section = try #require(ToolGroup.promptSection([bigGroup(), smallGroup()]))
        #expect(section.components(separatedBy: "\n").count == 3)
        #expect(section.contains("- linear: Issues and projects. Tools: "))
        #expect(section.contains("and 17 more"))
        // 29 tools cost a few hundred characters, not tens of thousands.
        #expect(section.count < 900)
    }

    @Test func modelOpensConnectorThenCallsItsTool() async throws {
        let seen = Seen()
        let provider = ScriptedProvider { request in
            let step = seen.record(request.tools.map(\.name))
            switch step {
            case 0:
                return .init(toolCalls: [ToolCall(name: "use_connector", arguments: ["connector": "linear", "need": "list issues"])])
            case 1: return .init(toolCalls: [ToolCall(name: "linear_list_issues", arguments: ["id": "me"])])
            default: return .init(text: "Done.")
            }
        }
        var agent = Agent(provider: provider, tools: [EchoTool()])
        agent.groups = [bigGroup(), smallGroup()]
        let events = try await collect(agent.run(messages: [.user("What is on my plate?")]))

        // Before opening, the model sees its own tools and the opener, not 29 connector tools.
        #expect(seen.steps[0] == ["echo", "use_connector"])
        #expect(seen.steps[1].count == 2 + ToolGroup.perOpen)
        #expect(seen.steps[1].contains("linear_list_issues"))
        #expect(events.toolMessages.map(\.text).last == "ran linear_list_issues")
        #expect(events.loadedTools.contains("linear_list_issues"))
    }

    @Test func openingAConnectorShowsItsOwnNotes() {
        var group = bigGroup()
        group.guidance = "Use list_issues with assignee \"me\" for the user's own issues."
        var shelf = ToolShelf(groups: [group])
        let result = shelf.open(["connector": "linear", "need": "my issues"], request: "")
        #expect(result.text.contains("How Linear says to use its tools: Use list_issues with assignee"))
    }

    @Test func resultsFromFinishedTurnsAreMadeSmall() async throws {
        let seen = SeenMessages()
        let provider = ScriptedProvider { request in
            seen.record(request.messages)
            return .init(text: "Done.")
        }
        let long = String(repeating: "A line of an old result. ", count: 400)
        let call = ToolCall(name: "fetch_page", arguments: [:])
        let history: [Message] = [
            .user("First"), Message(role: .assistant, text: "", toolCalls: [call]), .tool(long, call: call, isError: false),
            Message(role: .assistant, text: "Answer"), .user("Second"),
        ]
        _ = try await collect(Agent(provider: provider).run(messages: history))
        let old = try #require(seen.last.first { $0.role == .tool })
        #expect(old.text.count < 800 && old.text.contains("cut off"))
    }

    @Test func aToolNamedInAResultIsLoaded() {
        var shelf = ToolShelf(groups: [bigGroup()])
        let named = shelf.loadNamed(in: "1. Use the `linear_list_issues` tool to get the issues.", request: "run my tickets skill")
        #expect(named && shelf.loaded.contains("linear_list_issues"))
        let nothing = shelf.loadNamed(in: "No tools are named here.", request: "")
        #expect(!nothing)
    }

    @Test func aNewMessagePicksAgainFromAConnectorInUse() {
        // The chat read issues; the next message asks to change one without naming the connector.
        var shelf = ToolShelf(groups: [bigGroup()], loaded: ["linear_list_issues", "linear_get_issue"])
        #expect(!shelf.loaded.contains("linear_save_issue"))
        let changed = shelf.refresh(for: "Close the first one")
        #expect(changed && shelf.loaded.contains("linear_save_issue"))
        // A connector the chat has not used is left shut.
        var unused = ToolShelf(groups: [bigGroup()])
        let opened = unused.refresh(for: "Close the first one")
        #expect(!opened && unused.loaded.isEmpty)
    }

    @Test func callingOneToolUnseenBringsItsNeighbours() {
        var shelf = ToolShelf(groups: [bigGroup()])
        let first = shelf.use("linear_list_issues", request: "add a comment to my open issue")
        #expect(first)
        #expect(shelf.loaded.contains("linear_save_comment"))
        #expect(shelf.loaded.contains("linear_list_issues"))
        let again = shelf.use("linear_list_issues", request: "anything")
        #expect(!again)
    }

    @Test func namingAConnectorOpensItAndItStaysOpen() async throws {
        let seen = Seen()
        let provider = ScriptedProvider { request in
            _ = seen.record(request.tools.map(\.name))
            return .init(text: "Done.")
        }
        var agent = Agent(provider: provider)
        agent.groups = [bigGroup(), smallGroup()]
        let events = try await collect(agent.run(messages: [.user("Show my open issues in Linear")]))
        #expect(seen.steps[0].contains("linear_list_issues"))
        #expect(!seen.steps[0].contains { $0.hasPrefix("deepwiki") })

        // The next turn gets the same tools back without asking again.
        let loaded = events.loadedTools
        agent.loadedToolNames = loaded
        _ = try await collect(agent.run(messages: [.user("Thanks")]))
        #expect(Array(seen.steps[1].dropFirst()) == loaded)
    }

    @Test func toolCalledUnseenRunsAndAFailureShowsItsParameters() async throws {
        let provider = ScriptedProvider(turns: [
            .init(toolCalls: [ToolCall(name: "deepwiki_ask_question", arguments: [:])]), .init(text: "Done."),
        ])
        var agent = Agent(provider: provider)
        agent.groups = [bigGroup(), smallGroup()]
        let events = try await collect(agent.run(messages: [.user("Hello")]))
        let result = try #require(events.toolMessages.first)
        #expect(result.text.contains("id is missing"))
        #expect(result.text.contains("This tool's parameters: "))
    }

    @Test func oldestToolsGoBackWhenTooManyAreOpen() {
        var shelf = ToolShelf(groups: [bigGroup()])
        _ = shelf.open(["connector": "linear", "need": "comments on an issue"], request: "")
        _ = shelf.open(["connector": "linear", "need": "project milestones"], request: "")
        _ = shelf.open(["connector": "linear", "need": "documents"], request: "")
        #expect(shelf.loaded.count <= ToolGroup.loadedLimit)
        #expect(shelf.loaded.contains("linear_list_documents"))
    }

    @Test func unknownConnectorListsTheRealOnes() {
        var shelf = ToolShelf(groups: [bigGroup(), smallGroup()])
        let result = shelf.open(["connector": "jira"], request: "")
        #expect(result.isError)
        #expect(result.text.contains("linear, deepwiki"))
    }
}

extension Array where Element == AgentEvent {
    fileprivate var loadedTools: [String] {
        var latest: [String] = []
        for case .toolsLoaded(let names) in self { latest = names }
        return latest
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var steps: [[String]] { lock.withLock { recorded } }
    func record(_ names: [String]) -> Int {
        lock.withLock {
            recorded.append(names)
            return recorded.count - 1
        }
    }
}

@Suite struct SchemaTrimTests {
    @Test func keepsNamesTypesAndRequiredAndDropsTheRest() {
        let schema: JSONValue = [
            "$schema": "https://json-schema.org/draft/2020-12/schema", "additionalProperties": false, "type": "object",
            "required": ["id"],
            "properties": [
                "id": ["type": "string", "minLength": 1, "description": .string("Issue ID. " + String(repeating: "More detail. ", count: 30))],
                "assignee": ["type": ["string", "null"], "description": "User"],
                "resolution": ["anyOf": [["type": "string", "enum": ["month", "year"]], ["type": "null"]], "description": "Precision"],
                "patch": [
                    "type": "array", "maxItems": 50,
                    "items": ["oneOf": [["type": "object", "properties": ["op": ["const": "replace"]], "required": ["op"]]]],
                ],
                "fields": ["type": "array", "items": ["type": "string", "enum": .array((0..<40).map { .string("f\($0)") })]],
            ],
        ]
        let trimmed = SchemaTrim.parameters(schema)
        #expect(trimmed["$schema"] == nil)
        #expect(trimmed["required"] == ["id"])
        let description = trimmed["properties"]?["id"]?["description"]?.stringValue ?? ""
        #expect(description.hasPrefix("Issue ID. More detail.") && description.hasSuffix("detail."))
        #expect(description.count <= SchemaTrim.parameterDescriptionLimit)
        #expect(trimmed["properties"]?["id"]?["minLength"] == nil)
        #expect(trimmed["properties"]?["assignee"]?["type"] == "string")
        #expect(trimmed["properties"]?["resolution"]?["enum"] == ["month", "year"])
        #expect(trimmed["properties"]?["patch"]?["items"] == ["type": "object"])
        // A long list of options is named in the description, not cut to a few that then look like all of them.
        #expect(trimmed["properties"]?["fields"]?["items"] == ["type": "string"])
        let options = trimmed["properties"]?["fields"]?["description"]?.stringValue ?? ""
        #expect(options.hasPrefix("Options: f0, f1,") && options.contains("f39"))
        #expect(trimmed.jsonString.count < schema.jsonString.count * 2 / 3)
    }

    @Test func openingStaysInsideTheTokenBudget() {
        let heavy = (0..<10).map { index in
            NamedTool(name: "big_tool\(index)", description: String(repeating: "issue words here ", count: 120))
        }
        var shelf = ToolShelf(groups: [ToolGroup(name: "big", title: "Big", tools: heavy)], contextTokens: 8192)
        _ = shelf.open(["connector": "big", "need": "issue"], request: "")
        let total = shelf.loadedSpecs.reduce(0) { $0 + $1.estimatedTokens }
        #expect(!shelf.loaded.isEmpty)
        #expect(total <= 2048)
    }
}

private final class SeenMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [[Message]] = []
    func record(_ messages: [Message]) { lock.withLock { requests.append(messages) } }
    var last: [Message] { lock.withLock { requests.last ?? [] } }
}

@Suite struct ToolRankingTests {
    private func names(_ need: String, request: String = "") -> [String] {
        bigGroup().pick(need, request: request).map(\.spec.name)
    }

    @Test func ticketsMeanIssues() {
        #expect(names("retrieve open Linear tickets").contains("linear_list_issues"))
        #expect(names("", request: "Check my open linear tickets").contains("linear_list_issues"))
    }

    @Test func aConnectorTheAppOpenedComesWithItsUsageNotes() {
        var group = bigGroup()
        group.guidance = "Use list_issues with assignee \"me\" for the user's own issues."
        var shelf = ToolShelf(groups: [group])
        #expect(shelf.usageNotes == nil)
        _ = shelf.preload(for: "Get my open linear tickets")
        #expect(shelf.usageNotes == "How Linear says to use its tools: Use list_issues with assignee \"me\" for the user's own issues.")
    }

    @Test func getWithNothingNamedMeansList() {
        #expect(names("Get my open linear tickets").first == "linear_list_issues")
        var shelf = ToolShelf(groups: [bigGroup()])
        let opened = shelf.preload(for: "Get my open linear tickets")
        #expect(opened)
        #expect(shelf.loaded.contains("linear_list_issues"))
    }

    @Test func aStrayWordInTheRequestDoesNotOutweighTheNeed() {
        // "documentation" is in the request; the model asked for issues.
        let picked = names("list issues", request: "search the documentation skill")
        #expect(picked.first == "linear_list_issues")
    }

    @Test func withNothingToGoOnTheMainToolsComeFirst() {
        let picked = names("do the thing")
        #expect(picked.contains("linear_list_issues") && picked.contains("linear_get_issue"))
    }

    @Test func anIdentifierBringsTheToolThatFetchesOne() {
        #expect(names("In Linear, what is the status of issue ENG-412?").contains("linear_get_issue"))
    }

    @Test func changingSomethingBringsTheSavingTool() {
        #expect(names("mark the issue not urgent").contains("linear_save_issue"))
    }
}
