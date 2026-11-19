import Foundation
import Testing

@testable import HarnessKit

struct EchoTool: Tool {
    var spec: ToolSpec {
        ToolSpec(name: "echo", description: "Echo", parameters: ["type": "object"])
    }
    func call(_ arguments: JSONValue) async -> ToolResult {
        ToolResult("echo: " + (arguments["text"]?.stringValue ?? ""))
    }
}

struct BigTool: Tool {
    var spec: ToolSpec { ToolSpec(name: "big", description: "Big", parameters: ["type": "object"]) }
    func call(_ arguments: JSONValue) async -> ToolResult {
        ToolResult(String(repeating: "x", count: 50_000))
    }
}

func collect(_ stream: AsyncThrowingStream<AgentEvent, Error>) async throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

extension Array where Element == AgentEvent {
    var assistantMessages: [Message] {
        compactMap { if case .assistantMessage(let message) = $0 { return message } else { return nil } }
    }
    var toolMessages: [Message] {
        compactMap { if case .toolFinished(let message) = $0 { return message } else { return nil } }
    }
    var stop: StopReason? {
        compactMap { if case .finished(let reason) = $0 { return reason } else { return nil } }.last
    }
}

@Suite struct AgentLoopTests {
    @Test func answersWithoutTools() async throws {
        let provider = ScriptedProvider(turns: [.init(reasoning: "hmm", text: "Hello there.")])
        let events = try await collect(Agent(provider: provider).run(messages: [.user("hi")]))
        #expect(events.assistantMessages.count == 1)
        #expect(events.assistantMessages[0].text == "Hello there.")
        #expect(events.assistantMessages[0].reasoning == "hmm")
        #expect(events.stop == .stop)
    }

    @Test func runsToolThenAnswers() async throws {
        let provider = ScriptedProvider(turns: [
            .init(toolCalls: [ToolCall(name: "echo", arguments: ["text": "ping"])]),
            .init(text: "Done."),
        ])
        let events = try await collect(
            Agent(provider: provider, tools: [EchoTool()]).run(messages: [.user("go")]))
        #expect(events.toolMessages.map(\.text) == ["echo: ping"])
        #expect(events.assistantMessages.last?.text == "Done.")
        #expect(events.stop == .stop)
    }

    @Test func toolResultIsSentBackToModel() async throws {
        let provider = ScriptedProvider { request in
            if let last = request.messages.last, last.role == .tool {
                return .init(text: "Tool said: \(last.text)")
            }
            return .init(toolCalls: [ToolCall(id: "c1", name: "echo", arguments: ["text": "a"])])
        }
        let events = try await collect(
            Agent(provider: provider, tools: [EchoTool()]).run(messages: [.user("go")]))
        #expect(events.assistantMessages.last?.text == "Tool said: echo: a")
        #expect(events.toolMessages.first?.toolCallID == "c1")
    }

    @Test func unknownToolBecomesErrorResult() async throws {
        let provider = ScriptedProvider(turns: [
            .init(toolCalls: [ToolCall(name: "nope", arguments: [:])]),
            .init(text: "Sorry."),
        ])
        let events = try await collect(
            Agent(provider: provider, tools: [EchoTool()]).run(messages: [.user("go")]))
        let result = try #require(events.toolMessages.first)
        #expect(result.isError)
        #expect(result.text.contains("echo"))
    }

    @Test func stopsAtStepLimitWithoutTools() async throws {
        // A model that always asks for a tool when it has any.
        let provider = ScriptedProvider { request in
            request.tools.isEmpty
                ? .init(text: "Final answer.")
                : .init(toolCalls: [ToolCall(name: "echo", arguments: ["text": .string(UUID().uuidString)])])
        }
        let events = try await collect(
            Agent(provider: provider, tools: [EchoTool()], maxSteps: 3).run(messages: [.user("go")]))
        #expect(events.toolMessages.count == 2)
        #expect(events.assistantMessages.last?.text == "Final answer.")
        // The turn says it was the limit that ended it, so the app can offer to carry on.
        #expect(events.stop == .steps)
        // One that ends by itself on its last step with nothing pending is simply over.
        let done = ScriptedProvider(turns: [.init(toolCalls: [ToolCall(name: "echo", arguments: ["text": "a"])]), .init(text: "Done.")])
        #expect(try await collect(Agent(provider: done, tools: [EchoTool()], maxSteps: 3).run(messages: [.user("go")])).stop == .stop)
    }

    @Test func theModelIsToldHowManyCallsItHasLeftWhileItCanStillAct() async throws {
        // A model that calls a tool for as long as it is let.
        let provider = ScriptedProvider { request in
            request.messages.last?.text.contains("no tool calls left") ?? false
                ? .init(text: "Here is what I found, and what is still to do.")
                : .init(toolCalls: [ToolCall(name: "echo", arguments: ["text": .string(UUID().uuidString)])])
        }
        // Thirteen steps: twelve that may call a tool, then the answer.
        let events = try await collect(Agent(provider: provider, tools: [EchoTool()], maxSteps: 13).run(messages: [.user("go")]))
        let results = events.toolMessages.map(\.text)
        #expect(results.count == 12)
        let noted = results.indices.filter { results[$0].contains("tool calls left") }
        // Told when a third are left and again at three, at the end of the result it has just read, and not otherwise.
        #expect(noted == [7, 8])
        #expect(results[7].hasSuffix("\n[You have 4 tool calls left in this turn.]"))
        #expect(results[8].hasSuffix("\n[You have 3 tool calls left in this turn. If they are not enough to finish, answer and say what is still to do.]"))
        #expect(events.assistantMessages.last?.text == "Here is what I found, and what is still to do.")

        // Carried on, the turn starts its count again, so what it was told goes. Earlier turns are left as they are.
        let call = ToolCall(name: "echo", arguments: [:])
        let earlier = Message.tool("old\n" + Agent.callsLeftNote(3, of: 7)!, call: call)
        let kept = Agent.withoutCallsLeftNotes(
            [earlier, .user("go")] + events.toolMessages + [.assistant("Here is what I found, and what is still to do.")])
        #expect(kept[0].text == earlier.text)
        #expect(!kept.dropFirst().contains { $0.text.contains("tool calls left") })
        #expect(kept[9].text == String(results[7].prefix { $0 != "\n" }) && kept.count == 15)

        // A short turn is told once, at three.
        #expect(Agent.callsLeftNote(3, of: 7) != nil)
        #expect(([1, 2] + Array(4...7)).allSatisfy { Agent.callsLeftNote($0, of: 7) == nil })
        #expect(Agent.callsLeftNote(8, of: 25) != nil && Agent.callsLeftNote(9, of: 25) == nil && Agent.callsLeftNote(2, of: 25) == nil)
        // Out of calls, it is told the turn is over and not the job.
        #expect(Agent.outOfCalls.contains("what is still to do") && Agent.outOfCalls.contains("The user can tell you to go on."))
    }

    @Test func wrapsUpWhenOutOfTimeWithToolsStillDeclared() async throws {
        // A model that keeps calling tools until told it has none left, and then answers.
        let provider = ScriptedProvider { request in
            let told = request.messages.last?.text.contains("no tool calls left") ?? false
            // The tools are still declared on the last step, so the start of the prompt is unchanged.
            return told
                ? .init(text: request.tools.isEmpty ? "Answered without tools." : "Answered in time.")
                : .init(toolCalls: [ToolCall(name: "echo", arguments: ["text": .string(UUID().uuidString)])])
        }
        var agent = Agent(provider: provider, tools: [EchoTool()], maxSteps: 8)
        agent.deadline = Date().addingTimeInterval(-1)
        let events = try await collect(agent.run(messages: [.user("go")]))
        // The first step always runs; the next one is the last.
        #expect(events.toolMessages.count == 1)
        #expect(events.assistantMessages.last?.text == "Answered in time.")
    }

    @Test func repeatedIdenticalCallIsRefused() async throws {
        let provider = ScriptedProvider { request in
            request.tools.isEmpty
                ? .init(text: "ok")
                : .init(toolCalls: [ToolCall(name: "echo", arguments: ["text": "same"])])
        }
        let events = try await collect(
            Agent(provider: provider, tools: [EchoTool()], maxSteps: 5).run(messages: [.user("go")]))
        let results = events.toolMessages
        #expect(results.count == 4)
        #expect(!results[1].isError)
        #expect(results[2].isError)
    }

    @Test func recoversWhenModelOnlyThinks() async throws {
        struct OverthinkingProvider: ModelProvider {
            func generate(_ request: GenerationRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
                AsyncThrowingStream { continuation in
                    if request.options.thinking == .off {
                        continuation.yield(.text("It is 4."))
                        continuation.yield(.finished(.stop, nil))
                    } else {
                        continuation.yield(.reasoning("Hmm, let me think about this at length"))
                        continuation.yield(.finished(.length, nil))
                    }
                    continuation.finish()
                }
            }
        }
        let events = try await collect(
            Agent(provider: OverthinkingProvider(), options: .init(thinking: .medium)).run(messages: [.user("2+2?")]))
        #expect(events.assistantMessages.count == 1)
        #expect(events.assistantMessages[0].text == "It is 4.")
        #expect(events.assistantMessages[0].reasoning.contains("at length"))
        #expect(events.stop == .stop)
    }

    @Test func longToolResultIsClipped() async throws {
        let provider = ScriptedProvider(turns: [
            .init(toolCalls: [ToolCall(name: "big", arguments: [:])]),
            .init(text: "ok"),
        ])
        let events = try await collect(
            Agent(provider: provider, tools: [BigTool()], maxToolResultCharacters: 1000)
                .run(messages: [.user("go")]))
        let text = try #require(events.toolMessages.first?.text)
        #expect(text.count < 1100)
        #expect(text.contains("Part 1 of"))
    }

    @Test func longTextIsReadAPartAtATime() async throws {
        struct FileTool: Tool {
            var spec: ToolSpec { ToolSpec(name: "file", description: "File", parameters: ["type": "object"]) }
            func call(_ arguments: JSONValue) async -> ToolResult {
                ToolResult((1...60).map { "line \($0) of the file" }.joined(separator: "\n"))
            }
        }
        // The model asks for the same file four times, once with another argument.
        let provider = ScriptedProvider { request in
            let asked = request.messages.filter { $0.role == .tool }.count
            return asked < 4
                ? .init(toolCalls: [ToolCall(name: "file", arguments: asked == 1 ? ["ref": "main"] : [:])])
                : .init(text: "ok")
        }
        let events = try await collect(
            Agent(provider: provider, tools: [FileTool()], maxToolResultCharacters: 700).run(messages: [.user("go")]))
        let results = events.toolMessages.map(\.text)
        #expect(results.count == 4)
        #expect(results[0].hasPrefix("line 1 of the file"))
        #expect(results[0].contains("Part 1 of 3"))
        #expect(results[0].contains("make this same call again"))
        // Each part starts where the last one ended, on a whole line.
        #expect(results[1].contains("Part 2 of 3"))
        #expect(results[2].contains("Part 3 of 3"))
        #expect(results[2].contains("line 60 of the file"))
        let body = results.prefix(3).map { $0.components(separatedBy: "\n[Part")[0] }.joined()
        #expect(body == (1...60).map { "line \($0) of the file" }.joined(separator: "\n"))
        #expect(results[3].contains("read all 3 parts"))
        #expect(!events.toolMessages.contains { $0.isError })
    }

    @Test func emptyAnswerAfterSecondTryIsExplained() async throws {
        struct OnlyThinks: ModelProvider {
            func generate(_ request: GenerationRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
                AsyncThrowingStream { continuation in
                    continuation.yield(.reasoning("Still thinking"))
                    continuation.yield(.finished(.length, nil))
                    continuation.finish()
                }
            }
        }
        let events = try await collect(Agent(provider: OnlyThinks()).run(messages: [.user("go")]))
        #expect(events.assistantMessages.last?.text.contains("could not finish") == true)
    }
}

@Suite struct ContextBudgetTests {
    @Test func leavesShortTranscriptAlone() {
        let messages: [Message] = [.system("s"), .user("hi"), .assistant("hello")]
        #expect(ContextBudget.fit(messages, budgetTokens: 1000) == messages)
    }

    @Test func shortensOldToolResultsFirst() {
        let call = ToolCall(id: "1", name: "t", arguments: [:])
        let messages: [Message] = [
            .system("s"), .user("first"), .assistant("", toolCalls: [call]),
            .tool(String(repeating: "a", count: 8000), call: call), .assistant("answer"),
            .user("second"),
        ]
        let fitted = ContextBudget.fit(messages, budgetTokens: 500)
        #expect(fitted.count == messages.count)
        #expect(fitted[3].text.count < 300)
        #expect(fitted.last?.text == "second")
    }

    @Test func dropsOldestTurnsButKeepsSystemAndLatestUser() {
        var messages: [Message] = [.system("system prompt")]
        for index in 0..<20 {
            messages.append(.user("question \(index) " + String(repeating: "q", count: 400)))
            messages.append(.assistant("answer \(index) " + String(repeating: "a", count: 400)))
        }
        messages.append(.user("latest"))
        let fitted = ContextBudget.fit(messages, budgetTokens: 800)
        #expect(fitted.first?.role == .system)
        #expect(fitted.last?.text == "latest")
        #expect(fitted.count < messages.count)
        #expect(fitted.reduce(0) { $0 + ContextBudget.estimateTokens($1) } <= 800)
        // The first kept non-system message starts a turn.
        #expect(fitted[1].role == .user)
    }
}

@Suite struct PromptBuilderTests {
    @Test func includesDateAndMemory() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_794_614_400)  // 2026-11-14
        let prompt = PromptBuilder.systemPrompt(
            preset: .chat, memory: "- Lives in Lisbon", date: date, calendar: calendar)
        #expect(prompt.contains("14 November 2026"))
        #expect(prompt.contains("Lives in Lisbon"))
    }

    @Test func omitsMemorySectionWhenEmpty() {
        let prompt = PromptBuilder.systemPrompt(preset: .chat, memory: "  \n")
        #expect(!prompt.contains("What you know about the user"))
    }

    @Test func builtInPromptsAreSmall() {
        for preset in HarnessPreset.builtIns {
            let prompt = PromptBuilder.systemPrompt(preset: preset, memory: "")
            #expect(ContextBudget.estimateTokens(prompt) < 300, "\(preset.name)")
        }
    }

    @Test func promptSaysNothingAboutParticularTools() {
        var preset = HarnessPreset.assistant
        preset.tools = [.webSearch, .fetchPage, .runJavaScript, .saveMemory]
        let prompt = PromptBuilder.systemPrompt(preset: preset, memory: "")
        for tool in BuiltInTool.allCases { #expect(!prompt.contains(tool.rawValue)) }
    }

    @Test func promptSaysKeepingMemoryIsTheAgentsJob() {
        var preset = HarnessPreset.assistant
        let empty = PromptBuilder.systemPrompt(preset: preset, memory: "")
        #expect(empty.contains("Keeping it up is your job") && empty.contains("Nothing yet."))
        #expect(PromptBuilder.systemPrompt(preset: preset, memory: "- Vegetarian").hasSuffix("What you know about the user:\n- Vegetarian"))
        // Memory switched off: nothing about keeping it, but what is saved is still shown.
        preset.tools = [.webSearch]
        let off = PromptBuilder.systemPrompt(preset: preset, memory: "- Vegetarian")
        #expect(!off.contains("your job") && off.hasSuffix("What you know about the user:\n- Vegetarian"))
    }
}

@Suite struct OutputCleanerTests {
    @Test func leavesCleanTextAlone() {
        #expect(OutputCleaner.clean(text: " Hello. ", reasoning: "r") == .init(reasoning: "r", text: "Hello."))
    }

    @Test func treatsTextBeforeBareCloseTagAsThinking() {
        let cleaned = OutputCleaner.clean(text: "Okay, the user asked.\n</think>\n\nIt is 4.")
        #expect(cleaned == .init(reasoning: "Okay, the user asked.", text: "It is 4."))
    }

    @Test func dropsRepeatedFinalAnswerBlock() {
        let cleaned = OutputCleaner.clean(text: "The result is **7**.\n\n<final_answer>\n7\n</final_answer>")
        #expect(cleaned.text == "The result is **7**.")
    }

    @Test func unwrapsFinalAnswerThatIsTheOnlyAnswer() {
        #expect(OutputCleaner.clean(text: "<final_answer>\n42\n</final_answer>").text == "42")
        // Still streaming: the closing tag has not arrived yet.
        #expect(OutputCleaner.clean(text: "<final_answer>\n4").text == "4")
    }

    @Test func agentAppliesCleaning() async throws {
        let provider = ScriptedProvider(turns: [.init(text: "thinking aloud </think> Done.")])
        let events = try await collect(Agent(provider: provider).run(messages: [.user("hi")]))
        #expect(events.assistantMessages.first?.text == "Done.")
        #expect(events.assistantMessages.first?.reasoning == "thinking aloud")
    }
}
