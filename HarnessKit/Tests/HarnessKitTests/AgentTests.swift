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
        #expect(text.contains("cut off"))
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
