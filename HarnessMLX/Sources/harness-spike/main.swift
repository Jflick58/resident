import Foundation
import HarnessKit
import HarnessMLX

/// The skills the eval suite's assistant has: the app's own, and one a model wrote on a phone.
let suiteSkills =
    Skill.builtIns + [
        Skill(
            name: "get-open-tickets", summary: "When the user asks for their open Linear tickets",
            instructions:
                "1. Use the `linear_list_issues` tool with assignee \"me\" to retrieve the issues. 2. Leave out any whose status is Done or Canceled. 3. Return the list with id, title, status and priority."
        )
    ]

/// The start of what Linear's server says about using its tools, as the app receives it.
/// HARNESS_GUIDANCE=0 leaves it out, to measure what it is worth.
let linearGuidance =
    ProcessInfo.processInfo.environment["HARNESS_GUIDANCE"] == "0"
    ? ""
    : """
        When passing string values to tools, send the content directly without escape sequences. For example, use real newlines in markdown content rather than literal backslash-n characters.

        Tools accept human-readable references, so you rarely need to look up IDs first: issue identifiers such as LIN-123, project identifiers such as P-ENG-12, team names or keys, user names or emails, and "me" for the authenticated user. Only call list_teams, list_users, or similar tools when a reference is ambiguous or unknown.

        Use list_issues for structured queries, such as the issues assigned to "me" in a team, status, label, project, or cycle, and its query parameter for keyword search. Results are paginated: when hasNextPage is true, pass the returned cursor to fetch the next page rather than assuming the first page is complete.
        """


// A command-line check of the whole harness against a real on-device model:
// fit check, download, load, then a set of tasks through the agent loop with
// the real tools. Prints what the model did and a score.
//
//   harness-spike [repo] [--setup core|all|brief|disclose|shell] [--thinking off|low|medium|high]
//                 [--only 1,2] [--repeat N] [--temperature T] [--out results.jsonl]
//                 [--no-constrain] [--probe] [--retrieval-only]
//
// Setups, for measuring how a small model copes with many tools:
//   core      the four built-in tools only (first six tasks)
//   all       built-in tools plus 46 connector tools, all declared, full descriptions
//   brief     the same, with one-sentence descriptions
//   disclose  built-in tools declared; connector tools picked per request by
//             retrieval and attached to it with full descriptions, plus find_tools
//   shell     one bash tool; everything else is a command with --help

struct Task_ {
    var prompt: String
    /// Tools that must run, or empty when the model should just answer.
    var tools: [String] = []
    /// At least one of these must run, when more than one tool can do the job.
    var anyTool: [String] = []
    /// Text the final answer should contain.
    var answer: String?
    /// The arguments of some call must contain one of these.
    var argsAny: [String] = []
    /// In the shell, plain bash can do this job, so no particular command is required.
    var shellFree = false
}

let tasks: [Task_] = [
    .init(prompt: "Hi! In one sentence, what can you help me with?"),
    .init(prompt: "What is 1234 * 5678 + 91?", tools: ["run_javascript"], answer: "7006743", shellFree: true),
    .init(prompt: "Please remember that I'm vegetarian.", tools: ["save_memory"]),
    .init(prompt: "Open https://example.com and tell me what the page says.", tools: ["fetch_page"], answer: "example"),
    .init(prompt: "Search the web: what is the latest stable version of the Swift programming language?", tools: ["web_search"], answer: "6"),
    .init(prompt: "How many days are there between 10 February 2024 and 14 November 2026?", tools: ["run_javascript"], answer: "1008", shellFree: true),
    // Connector tasks: the answer exists only in a connector's data.
    .init(prompt: "What's on my calendar tomorrow?", tools: ["calendar_list"], answer: "dentist"),
    .init(prompt: "Remind me to call the plumber tomorrow at 5pm.", tools: ["reminders_add"], argsAny: ["plumber"]),
    .init(prompt: "How many open issues does the GitHub repo acme/rocket have, and what is the oldest one about?", tools: ["github_issues"], answer: "fuel"),
    .init(prompt: "What's Maria Lopez's phone number?", tools: ["contacts_search"], answer: "555-0142"),
    .init(prompt: "How many steps did I walk yesterday?", tools: ["health_steps"], answer: "8412"),
    .init(prompt: "What's the weather in Lisbon right now?", tools: ["weather_current"], answer: "19"),
    .init(prompt: "Find my note about the wifi password and tell me the password.", tools: ["notes_read"], answer: "tangerine-42"),
    .init(prompt: "Look at my calendar for tomorrow and add a reminder to leave the house 30 minutes before my first event.", tools: ["calendar_list", "reminders_add"], argsAny: ["09:00", "9:00", "9 am", "9am"]),
    .init(prompt: "What is the capital of Australia?", answer: "canberra"),
    .init(prompt: "How long will it take to drive from home to the airport right now?", tools: ["maps_travel_time"], answer: "42"),
    .init(prompt: "Do I have any unread email from my landlord? What does it say?", tools: ["mail_read"], answer: "boiler"),
]

func residentMemory() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
}

var arguments = Array(CommandLine.arguments.dropFirst())
var thinking = ThinkingLevel.low
var only: Set<Int>?
var setup = "core"
var repeats = 1
var outPath: String?
var temperature: Double?
var retrievalOnly = false
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}
if let value = option("--setup") { setup = value }
if let value = option("--repeat") { repeats = Int(value) ?? 1 }
if let value = option("--out") { outPath = value }
if let value = option("--temperature") { temperature = Double(value) }
// --suite <folder|file|all>: run the eval cases kept as data (evals/cases) in place of the tasks above.
// --sample N [--seed S] runs about N of them, the same ones each time; --category a,b keeps those
// categories; --label names the run in the results; --resume skips cases the --out file already has.
let suitePath = option("--suite")
let sampleSize = option("--sample").flatMap { Int($0) }
let sampleSeed = option("--seed").flatMap { Int($0) } ?? 1
let onlyCategories = option("--category").map { Set($0.split(separator: ",").map(String.init)) }
let runLabel = option("--label") ?? ""
// --ids a,b: only the cases whose id starts with one of these.
let onlyIDs = option("--ids")?.split(separator: ",").map(String.init)
let resumes = arguments.contains("--resume")
arguments.removeAll { $0 == "--resume" }
if suitePath != nil { setup = "suite" }
if let index = arguments.firstIndex(of: "--retrieval-only") {
    arguments.remove(at: index)
    retrievalOnly = true
}
if let index = arguments.firstIndex(of: "--thinking"), index + 1 < arguments.count {
    thinking = ThinkingLevel(rawValue: arguments[index + 1]) ?? .low
    arguments.removeSubrange(index...index + 1)
}
if let value = option("--only") { only = Set(value.split(separator: ",").compactMap { Int($0) }) }
if let index = arguments.firstIndex(of: "--no-constrain") {
    arguments.remove(at: index)
    await MLXEngine.shared.setConstrainsToolCalls(false)
}
// --probe: a self-check that the grammar really constrains output. The model is
// shown an ordinary code tool, while the grammar only admits one fixed argument
// value that no model would produce by itself.
// --apple: run the general tasks with the system's own model (Apple Intelligence) instead of an MLX model.
let useApple = arguments.contains("--apple")
arguments.removeAll { $0 == "--apple" }
let probe = arguments.contains("--probe")
arguments.removeAll { $0 == "--probe" }
// --image <path>: describe one image and exit, to check that a vision model sees.
let imagePath = option("--image")
// --chat "first|second|…": one chat of several turns, to check that each turn
// only processes what is new.
let chatTurns = option("--chat")?.components(separatedBy: "|")
// --save <path>: write the chat's messages as JSON, in the form the app keeps them.
let savePath = option("--save")
let repo = ModelFit.repoID(from: arguments.first ?? "mlx-community/Qwen3-4B-4bit") ?? "mlx-community/Qwen3-4B-4bit"

// MARK: Tools for each setup

let recorder = CallRecorder()
let memory = MemoryStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("harness-spike-memory-\(UUID().uuidString).md"))
let coreTools: [any Tool] = [WebSearchTool(), FetchPageTool(), JavaScriptTool(), SaveMemoryTool(store: memory)]
let recordedCore: [any Tool] = coreTools.map { RecordedTool(base: $0, recorder: recorder) }
let connectors: [ConnectorTool] = connectorTools.map { tool in
    var tool = tool
    tool.recorder = recorder
    tool.useBrief = setup == "brief"
    return tool
}
let toolIndex = ToolIndex(tools: connectors.map(\.spec))
/// Connector tools attached to each request in the disclose setup.
let disclosedPerRequest = 4
/// Connectors attached whole in the disclose setup.
let connectorsPerRequest = 2

/// The tools to attach to a request: every tool of the connectors that the
/// best-ranked tools belong to. Attaching whole connectors means a follow-up
/// tool (read after search) is there even though the request did not name it.
func toolsToAttach(_ prompt: String) -> [ToolSpec] {
    var groups: [String] = []
    for spec in toolIndex.rank(prompt) {
        let group = String(spec.name.prefix { $0 != "_" })
        if !groups.contains(group) { groups.append(group) }
        if groups.count == connectorsPerRequest { break }
    }
    return groups.flatMap { group in connectors.filter { $0.group == group }.map(\.spec) }
}

if retrievalOnly {
    // How often the right tool is among the ones retrieval would attach. No model involved.
    print("Embedder: \(toolIndex.embedderName). \(connectors.count) connector tools.")
    for method in [ToolIndex.Method.embedding, .keyword, .fused] {
        var hits = 0
        var total = 0
        var lines: [String] = []
        for task in tasks {
            let wanted = task.tools.filter { name in connectors.contains { $0.name == name } }
            guard !wanted.isEmpty else { continue }
            let ranked = toolIndex.rank(task.prompt, method: method).map(\.name)
            // For notes and mail the first step is a search the model must make before the scored tool.
            let ranks = wanted.map { (ranked.firstIndex(of: $0) ?? 99) + 1 }
            total += wanted.count
            hits += ranks.filter { $0 <= disclosedPerRequest }.count
            lines.append("  \(zip(wanted, ranks).map { "\($0) #\($1)" }.joined(separator: ", "))   top: \(ranked.prefix(disclosedPerRequest).joined(separator: " "))")
        }
        print("\n\(method.rawValue): \(hits)/\(total) expected tools in the top \(disclosedPerRequest)")
        lines.forEach { print($0) }
    }
    var hits = 0
    var total = 0
    var sizes: [Int] = []
    for task in tasks {
        let wanted = task.tools.filter { name in connectors.contains { $0.name == name } }
        guard !wanted.isEmpty else { continue }
        let attached = toolsToAttach(task.prompt)
        sizes.append(attached.count)
        total += wanted.count
        hits += wanted.filter { name in attached.contains { $0.name == name } }.count
    }
    print("\nwhole connectors (top \(connectorsPerRequest), fused): \(hits)/\(total) expected tools attached, \(sizes.reduce(0, +) / max(1, sizes.count)) tools per request on average")
    exit(0)
}

/// The model under test: one run by MLX, or the system's own.
func modelProvider(_ contextTokens: Int) -> any ModelProvider {
    if useApple, #available(macOS 26.0, *) { return AppleModelProvider() }
    return MLXEngine.shared.provider(contextTokens: contextTokens)
}

/// The system model's context size. Stops the run if the model cannot be used.
/// In a function of its own: an availability check beside awaits in the
/// top-level code made the Swift runtime abort ("freed pointer was not the last allocation").
func appleModelContext() -> Int {
    guard #available(macOS 26.0, *) else { fatalError("Apple Intelligence needs macOS 26 or later.") }
    if let reason = AppleModelProvider.unavailableReason { fatalError(reason) }
    return AppleModelProvider.contextTokens
}

var modelContext = 8192
if useApple {
    modelContext = appleModelContext()
    print("== Apple Intelligence  setup=\(setup)  context=\(modelContext)")
} else {
    print("== \(repo)  setup=\(setup)  thinking=\(thinking.rawValue)")
    let info = try await HubMetadataClient().info(repo: repo)
    let phone = DeviceProfile(memoryBudgetBytes: 6 << 30, freeDiskBytes: DeviceProfile.current().freeDiskBytes)
    let report = ModelFit.evaluate(info, device: phone)
    modelContext = max(report.contextTokens, 8192)
    print("Fit on a 6 GB phone: \(report.headline). \(report.detail)")
    print("Capabilities: vision=\(report.capabilities.vision) tools=\(report.capabilities.tools) thinking=\(report.capabilities.thinking)  download=\(ModelFit.format(report.downloadBytes))")
    if !report.canInstall { print("Fit check says no; continuing anyway for the spike.") }

    let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("harness-spike/models")
    let directory = root.appendingPathComponent(ModelDownloader.folderName(for: repo))
    if !ModelDownloader.isComplete(info, in: directory) {
        print("Downloading to \(directory.path)")
        var lastPrinted = -1
        try await ModelDownloader().download(info, to: directory) { progress in
            let percent = Int(progress.fraction * 100)
            if percent / 10 != lastPrinted / 10 {
                lastPrinted = percent
                print("  \(percent)%")
            }
        }
    }

    let loadStart = Date()
    try await MLXEngine.shared.load(directory: directory)
    print(String(format: "Loaded in %.1fs, memory %@", Date().timeIntervalSince(loadStart), ModelFit.format(residentMemory())))
}

let probeGrammar = ToolSpec(
    name: "run_javascript", description: "",
    parameters: [
        "type": "object", "properties": ["code": ["type": "string", "enum": ["GRAMMAR_PROBE"]]],
        "required": ["code"],
    ])
// --memory-pass "first|second|…": what the memory pass keeps from each message.
if let lines = option("--memory-pass")?.components(separatedBy: "|") {
    var known = ["The user is vegetarian."]
    for line in lines {
        let start = Date()
        let update = await Housekeeping.memoryUpdate(from: line, known: known, provider: modelProvider(4096))
        print(String(format: "%@\n   %.1fs  keep %@  forget %@", line, Date().timeIntervalSince(start), "\(update.facts)", "\(update.forget)"))
        known += update.facts
    }
    let sample: [Message] = [
        .user("Check my open Linear tickets"),
        .assistant("You have five open issues: ENG-459 team offsite plan (medium), ENG-458 an unpaid invoice of $138.68 (high), ENG-425 contract paperwork (medium), ENG-457 insurance form due 17 November (urgent), ENG-456 return the loaned test phone by 2 December (urgent)."),
        .user("For 456 does it say how to return the device?"),
        .assistant("Yes. ENG-456 says to return the loaned test phone through a courier drop-off by 2 December 2026 to avoid the $330 charge."),
        .user("Can you mark the invoice one not urgent?"),
        .assistant("Done. ENG-458 is now medium priority instead of high."),
    ]
    let summary = await Housekeeping.summary(of: sample, previous: nil, provider: modelProvider(4096))
    print("summary: \(summary ?? "nil")")
    let title = await Housekeeping.title(
        question: "Check my open linear tickets", answer: "You have five open issues, the most urgent being an insurance application.",
        provider: modelProvider(4096))
    print("title: \(title ?? "nil")")
    exit(0)
}
// --offers: when does the model offer to save a skill? Runs requests that should
// and should not draw an offer. HARNESS_SKILL_GUIDANCE replaces the sentence in
// the prompt, to compare wordings without rebuilding.
if arguments.contains("--offers") {
    let cases: [(prompt: String, wanted: Bool)] = [
        ("Find the latest stable versions of Swift, Rust and Go and compare their release dates in one line.", true),
        ("Look up today's price of Bitcoin and of Ethereum and work out how many Ethereum one Bitcoin buys.", true),
        ("When I ask for a standup update, give me three bullets: yesterday, today, blockers, each under 12 words.", true),
        ("Find three well-reviewed vegetarian restaurants in Sacramento and tell me which is open latest.", true),
        ("What is the capital of France?", false),
        ("What is 1234 * 5678 + 91?", false),
        ("Write a haiku about rain.", false),
        ("Search the web: who won the last Formula 1 race?", false),
    ]
    var prompt = PromptBuilder.systemPrompt(preset: .assistant, memory: "", skills: Skill.builtIns)
    if let wording = ProcessInfo.processInfo.environment["HARNESS_SKILL_GUIDANCE"] {
        prompt = prompt.replacingOccurrences(of: Skill.savingGuidance, with: wording)
    }
    var right = 0
    for item in cases {
        let agent = Agent(
            provider: modelProvider(16384),
            tools: [
                JavaScriptTool(), WebSearchTool(), FetchPageTool(), SaveMemoryTool(store: memory), UseSkillTool(skills: Skill.builtIns),
                SaveSkillTool { $0 },
            ],
            options: .init(maxOutputTokens: 800, temperature: 0.6, thinking: .low))
        var calls: [String] = []
        var answer = ""
        for try await event in agent.run(messages: [.system(prompt), .user(item.prompt)]) {
            if case .assistantMessage(let message) = event {
                calls += message.toolCalls.map(\.name)
                if message.toolCalls.isEmpty { answer = message.text }
            }
        }
        let offered = calls.contains(SaveSkillTool.name) || answer.lowercased().contains("skill")
        if offered == item.wanted { right += 1 }
        print("\(offered == item.wanted ? "ok  " : "MISS") wanted=\(item.wanted) offered=\(offered) calls=\(calls.count) \(calls.contains(SaveSkillTool.name) ? "[saved without asking] " : "")| \(item.prompt.prefix(50))")
        print("       …" + String(answer.suffix(150)).replacingOccurrences(of: "\n", with: " / "))
    }
    print("== offers: \(right)/\(cases.count) as wanted")
    exit(0)
}
if let chatTurns {
    // HARNESS_GATE_TEST: hold generation for three seconds part-way through, as leaving the app would.
    if ProcessInfo.processInfo.environment["HARNESS_GATE_TEST"] != nil {
        Task.detached {
            try? await Task.sleep(for: .milliseconds(1500))
            GenerationGate.close()
            print("  [gate closed]")
            try? await Task.sleep(for: .seconds(3))
            print("  [gate opened]")
            GenerationGate.open()
        }
    }
    // HARNESS_TOOLS: how much of the harness the model is given. "full" (the default), "noskills", or "web"
    // (web search, page reading and code only, with nothing about memory or skills in the prompt).
    let surface = ProcessInfo.processInfo.environment["HARNESS_TOOLS"] ?? "full"
    var chatPreset = HarnessPreset.assistant
    if surface != "full" { chatPreset.tools.removeAll { $0 == .skills } }
    if surface == "web" { chatPreset.tools.removeAll { $0 == .saveMemory } }
    var chatTools: [any Tool] = [JavaScriptTool(), WebSearchTool(), FetchPageTool()]
    if surface != "web" { chatTools.append(SaveMemoryTool(store: memory)) }
    // With Linear, the chat also has a skill a model wrote on the phone, to test changing one.
    let chatSkills =
        Skill.builtIns
        + (setup == "linear"
            ? [
                Skill(
                    name: "get-open-tickets", summary: "When the user asks for their open Linear tickets",
                    instructions:
                        "1. Use the `linear_list_issues` tool with appropriate filters to retrieve the issues. 2. Filter the results for those with status not equal to 'Closed' or 'Resolved'. 3. Optionally, specify fields like id, title, status, priority, assignee, dueDate. 4. Return the list to me."
                )
            ] : [])
    if surface == "full" {
        chatTools.append(UseSkillTool(skills: chatSkills))
        chatTools.append(
            SaveSkillTool(existing: chatSkills) { skill in
                print("  PROPOSED SKILL \(skill.name) | \(skill.summary) | \(skill.instructions.replacingOccurrences(of: "\n", with: " / "))")
                return skill
            })
        chatTools.append(
            UpdateSkillTool(skills: chatSkills) { skill in
                print("  PROPOSED CHANGE to \(skill.name) | \(skill.summary) | \(skill.instructions.replacingOccurrences(of: "\n", with: " / "))")
                return skill
            })
    }
    // With --setup linear the chat has Linear's connector, opened on demand as in the app.
    let chatGroups =
        setup == "linear"
        ? [ToolGroup(name: "linear", title: "Linear", summary: "Issues and projects", tools: loadLinearTools(recorder: recorder), guidance: linearGuidance)] : []
    var messages: [Message] = [
        .system(
            PromptBuilder.systemPrompt(
                preset: chatPreset, memory: "", skills: surface == "full" ? chatSkills : [], connectors: chatGroups))
    ]
    var loaded: [String] = []
    for turn in chatTurns {
        if turn == "DRAFT" {
            // Draft a skill from the first turn, as the Save as Skill button would.
            let end = messages.dropFirst(2).firstIndex { $0.role == .user } ?? messages.count
            let skill = await Housekeeping.skillDraft(from: Array(messages[1..<end]), provider: modelProvider(4096))
            print("--- draft\n  \(skill.map { "\($0.name) | \($0.summary)\n  " + $0.instructions.replacingOccurrences(of: "\n", with: "\n  ") } ?? "nil")")
            continue
        }
        messages.append(.user(turn))
        var agent = Agent(
            provider: modelProvider(16384), tools: chatTools,
            options: .init(maxOutputTokens: 600, temperature: 0.6, thinking: .low))
        agent.loadedToolNames = loaded
        agent.groups = chatGroups
        var plainPreset = HarnessPreset.assistant
        plainPreset.tools = []
        agent.plainInstructions = PromptBuilder.systemPrompt(preset: plainPreset, memory: "", canRemember: false)
        print("--- \(turn)")
        for try await event in agent.run(messages: messages) {
            switch event {
            case .assistantMessage(let message):
                messages.append(message)
                if message.toolCalls.isEmpty { print("  answer: …" + String(message.text.suffix(260)).replacingOccurrences(of: "\n", with: " / ")) }
                let stats = message.stats
                print(String(format: "  step: prompt %d tokens, first token %.1fs%@", stats?.promptTokens ?? -1, stats?.timeToFirstToken ?? -1,
                    message.toolCalls.isEmpty ? "" : "  calls " + message.toolCalls.map { $0.name + " " + $0.arguments.jsonString }.joined(separator: ", ")))
            case .toolFinished(let message): messages.append(message)
            case .toolsLoaded(let names):
                loaded = names
                print("  tools: " + names.joined(separator: ", "))
            default: break
            }
        }
    }
    if let savePath {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(messages.filter { $0.role != .system }).write(to: URL(fileURLWithPath: savePath))
    }
    exit(0)
}
if let imagePath {
    let data = try Data(contentsOf: URL(fileURLWithPath: imagePath))
    let agent = Agent(
        provider: modelProvider(8192), tools: [],
        options: .init(maxOutputTokens: 400, temperature: 0.6, thinking: .off))
    let start = Date()
    var reply = ""
    for try await event in agent.run(messages: [
        .user("Describe this picture in two sentences. Then read out any text in it.", images: [ImageAttachment(data: data)])
    ]) {
        if case .textDelta(let delta) = event { reply += delta }
    }
    print(String(format: "Image reply (%.1fs, memory %@):\n%@", Date().timeIntervalSince(start), ModelFit.format(residentMemory()), reply))
    exit(0)
}
if probe {
    await MLXEngine.shared.setGrammarToolsForTesting([probeGrammar])
    let agent = Agent(
        provider: modelProvider(8192), tools: [JavaScriptTool()],
        options: .init(maxOutputTokens: 512, temperature: 0.6, thinking: .off))
    var arguments: [String] = []
    for try await event in agent.run(messages: [.system("Use run_javascript for arithmetic."), .user("What is 1234 * 5678 + 91?")]) {
        if case .toolStarted(let call, _) = event { arguments.append(call.arguments.jsonString) }
    }
    print("Probe tool calls: \(arguments)")
    print(arguments.first == #"{"code":"GRAMMAR_PROBE"}"# ? "GRAMMAR ENFORCED" : "GRAMMAR NOT ENFORCED")
    exit(0)
}

// MARK: Prompt and agent for the setup

var preset = HarnessPreset.assistant
preset.thinking = thinking
if let temperature { preset.temperature = temperature }
let contextTokens = modelContext
let connectorIndex = connectorSummaries.map { "- \($0.group): \($0.summary)" }.joined(separator: "\n")

var agentTools: [any Tool]
var declared: Set<String>?
var systemText: String
var taskRange = tasks.indices
var groups: [ToolGroup] = []
var activeTasks = tasks

switch setup {
case "core":
    agentTools = recordedCore
    systemText = PromptBuilder.systemPrompt(preset: preset, memory: "")
    taskRange = 0..<6
case "all", "brief":
    agentTools = recordedCore + connectors
    systemText = PromptBuilder.systemPrompt(preset: preset, memory: "")
case "open":
    // What the app does with many tools: one line per connector, opened on demand.
    agentTools = recordedCore
    groups = connectorSummaries.map { group, summary in
        ToolGroup(name: group, title: group, summary: summary, tools: connectors.filter { $0.group == group })
    }
    systemText = PromptBuilder.systemPrompt(preset: preset, memory: "", connectors: groups)
case "linear", "linear-all":
    // One connector of Linear's real size next to the usual ones, either opened
    // on demand as in the app or with every tool declared.
    let linear = loadLinearTools(recorder: recorder)
    activeTasks = linearTasks
    taskRange = linearTasks.indices
    if setup == "linear" {
        agentTools = recordedCore
        groups = connectorSummaries.map { group, summary in
            ToolGroup(name: group, title: group, summary: summary, tools: connectors.filter { $0.group == group })
        } + [ToolGroup(name: "linear", title: "Linear", summary: "Issues and projects", tools: linear, guidance: linearGuidance)]
    } else {
        agentTools = recordedCore + connectors + linear
    }
    systemText = PromptBuilder.systemPrompt(preset: preset, memory: "", connectors: groups)
case "suite":
    // The world the eval cases run in: the app's built-in tools with the web faked,
    // skills, the 13 stand-in connectors and Linear, all opened on demand.
    let web = WebFixtures.load()
    let suiteCore: [any Tool] = [web.searchTool(), web.fetchTool(), JavaScriptTool(), SaveMemoryTool(store: memory), UseSkillTool(skills: suiteSkills)]
    agentTools = suiteCore.map { RecordedTool(base: $0, recorder: recorder) }
    // GitHub and Linear are their real tool definitions; the toy GitHub of the older setups stays out.
    groups = ToolGroup.linking(connectorSummaries.filter { $0.group != "github" }.map { group, summary in
        ToolGroup(name: group, title: group, summary: summary, tools: connectors.filter { $0.group == group })
    } + [
        ToolGroup(name: "github", title: "GitHub", summary: "Repositories, issues and pull requests", tools: FileEditTool.adding(to: loadGitHubTools(recorder: recorder), title: "GitHub")),
        ToolGroup(name: "linear", title: "Linear", summary: "Issues and projects", tools: loadLinearTools(recorder: recorder), guidance: linearGuidance),
    ], to: suiteSkills)
    systemText = PromptBuilder.systemPrompt(preset: preset, memory: "", skills: suiteSkills, connectors: groups)
case "disclose":
    let finder = FindToolsTool(index: toolIndex, count: disclosedPerRequest)
    agentTools = recordedCore + [finder] + connectors
    declared = Set(recordedCore.map(\.spec.name) + [finder.spec.name])
    systemText = PromptBuilder.systemPrompt(preset: preset, memory: "") + """


        You can also reach these connectors:
        \(connectorIndex)
        Tools for the connectors that look relevant are listed with each request. \
        If you need a connector tool that is not listed, call find_tools and say what you need.
        """
case "shell":
    var commands = [
        shellCommand("search", summary: "search the web", wrapping: coreTools[0], recorder: recorder),
        shellCommand("fetch", summary: "read a web page as text", wrapping: coreTools[1], recorder: recorder),
        shellCommand("js", summary: "run JavaScript code", wrapping: coreTools[2], recorder: recorder),
        shellCommand("remember", summary: "save a lasting fact about the user", wrapping: coreTools[3], recorder: recorder),
    ]
    for (group, summary) in connectorSummaries {
        commands.append(
            ShellCommand(
                name: group, summary: summary,
                actions: connectors.filter { $0.group == group }.map { ($0.action, $0) }))
    }
    let bridgeDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shell-bridge")
    let bridge = try ShellBridge(directory: bridgeDirectory, commands: commands)
    agentTools = [BashTool(bridge: bridge)]
    var bare = preset
    bare.tools = []
    systemText = PromptBuilder.systemPrompt(preset: bare, memory: "") + """


        You act through one tool, bash: a sandboxed shell with its own file system. \
        Standard commands work (ls, cat, grep, head, sed, awk, jq, wc, date, and $((...)) for arithmetic).
        These extra commands reach the web and the user's data:
        \(commands.map { "- \($0.name): \($0.summary)" }.joined(separator: "\n"))
        Run `<command> --help` before the first time you use one of them; it shows the exact usage.
        Your knowledge is out of date: for news, versions or anything recent, use search, then fetch the best result.
        When the user shares a lasting fact or preference about themselves, use remember.
        Long output is cut off: redirect it to a file and use grep or head on it.
        Answer directly when no command is needed.
        """
default:
    print("Unknown setup \(setup)")
    exit(2)
}

var agent = Agent(
    provider: modelProvider(contextTokens), tools: agentTools,
    options: preset.options, contextBudgetTokens: contextTokens * 3 / 4)
agent.declaredToolNames = declared
agent.groups = groups
// As the app does: the prompt with nothing about tools, for a provider that answers some requests without any.
var plainPreset = preset
plainPreset.tools = []
agent.plainInstructions = PromptBuilder.systemPrompt(preset: plainPreset, memory: "", canRemember: false)
// HARNESS_PREAMBLE: a sentence added to the prompt, to try wordings that ask the model to say what it is about to do.
if let extra = ProcessInfo.processInfo.environment["HARNESS_PREAMBLE"] { systemText += "\n\n" + extra }
let system = Message.system(systemText)
var spokeBeforeCall = 0
var callingSteps = 0
print("System prompt: \(systemText.count) characters. Tools declared: \(declared?.count ?? agentTools.count) of \(agentTools.count).")

// MARK: The eval suite

var peak: Int64 = 0

if let suitePath {
    setvbuf(stdout, nil, _IOLBF, 0)
    var cases = try EvalSuite.load(suitePath)
    if let onlyCategories { cases = cases.filter { onlyCategories.contains($0.category) } }
    if let onlyIDs { cases = cases.filter { item in onlyIDs.contains { item.id.hasPrefix($0) } } }
    if let sampleSize { cases = EvalSuite.sample(cases, count: sampleSize, seed: sampleSeed) }
    let modelName = useApple ? "apple" : repo
    let done = resumes ? EvalSuite.finished(in: outPath ?? "", model: modelName, label: runLabel) : []
    print("Suite: \(cases.count) cases\(done.isEmpty ? "" : ", \(done.count) already done")")
    var tally: [String: (passed: Int, total: Int)] = [:]
    var failed: [String] = []
    var seconds: [Double] = []
    let suiteStart = Date()
    for (position, item) in cases.enumerated() where !done.contains(item.id) {
        print("\n--- [\(position + 1)/\(cases.count)] \(item.id)  \(item.turns.joined(separator: " | "))")
        _ = recorder.take()
        memory.setFacts([])
        GitHubState.shared.reset()
        var messages: [Message] = [
            .system(PromptBuilder.systemPrompt(preset: preset, memory: item.memory ?? "", skills: suiteSkills, connectors: groups))
        ]
        var loaded: [String] = []
        var calls: [[(name: String, arguments: String)]] = []
        var answer = ""
        var steps = 0
        var problem: String?
        let start = Date()
        for turn in item.turns {
            messages.append(.user(turn))
            agent.loadedToolNames = loaded
            answer = ""
            do {
                for try await event in agent.run(messages: messages) {
                    switch event {
                    case .toolStarted(let call, _): print("  call  \(call.name) \(call.arguments.jsonString.prefix(200))")
                    case .toolFinished(let message):
                        messages.append(message)
                        print("  \(message.isError ? "error" : "result") \(message.text.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(200))")
                    case .assistantMessage(let message):
                        messages.append(message)
                        steps += 1
                        if message.toolCalls.isEmpty { answer = message.text }
                    case .toolsLoaded(let names): loaded = names
                    default: break
                    }
                    peak = max(peak, residentMemory())
                }
            } catch {
                problem = error.localizedDescription
            }
            calls.append(recorder.take())
            if problem != nil { break }
        }
        let elapsed = Date().timeIntervalSince(start)
        let failure = problem ?? item.failure(calls: calls, answer: answer)
        print("  answer: \(answer.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(300))")
        print(String(format: "  %@  %.1fs  %d steps%@", failure == nil ? "PASS" : "FAIL", elapsed, steps, failure.map { "  (\($0))" } ?? ""))
        tally[item.category, default: (0, 0)].total += 1
        if failure == nil { tally[item.category]!.passed += 1 } else { failed.append("\(item.id): \(failure!)") }
        seconds.append(elapsed)
        if let outPath {
            EvalSuite.append(
                [
                    "id": .string(item.id), "category": .string(item.category), "pass": .bool(failure == nil),
                    "failure": .string(failure ?? ""), "seconds": .double((elapsed * 10).rounded() / 10), "steps": .int(steps),
                    "calls": .array(calls.flatMap { $0 }.map { .string($0.name) }), "answer": .string(String(answer.prefix(300))),
                    "model": .string(modelName), "thinking": .string(thinking.rawValue), "label": .string(runLabel),
                ], to: outPath)
        }
    }
    let ran = tally.values.reduce(0) { $0 + $1.total }
    let right = tally.values.reduce(0) { $0 + $1.passed }
    print("\n== \(modelName)\(runLabel.isEmpty ? "" : " [\(runLabel)]"), thinking \(thinking.rawValue)")
    for (category, score) in tally.sorted(by: { $0.key < $1.key }) {
        print("   \(category.padding(toLength: 12, withPad: " ", startingAt: 0)) \(score.passed)/\(score.total)")
    }
    let range = EvalSuite.interval(passed: right, of: ran)
    print(String(format: "   total        %d/%d  (%d%%, likely between %d%% and %d%%)  %.1fs a case, %.0f minutes in all",
        right, ran, ran == 0 ? 0 : right * 100 / ran, range.low, range.high, seconds.isEmpty ? 0 : seconds.reduce(0, +) / Double(seconds.count),
        Date().timeIntervalSince(suiteStart) / 60))
    failed.forEach { print("   fail \($0)") }
    exit(0)
}

// MARK: Run

var passed = 0
var total = 0
var promptSizes: [Int] = []
var durations: [Double] = []
var stepCounts: [Int] = []
var failures: [String] = []
var loadedSizes: [Int] = []

for round in 0..<repeats {
    for index in taskRange where only == nil || only!.contains(index) {
        let task = activeTasks[index]
        total += 1
        print("\n--- [\(index)\(repeats > 1 ? " r\(round + 1)" : "")] \(task.prompt)")
        var prompt = task.prompt
        if setup == "disclose" {
            let picked = toolsToAttach(task.prompt)
            print("  attached: \(picked.map(\.name).joined(separator: " "))")
            prompt = ToolDisclosure.attach(picked, to: prompt)
        }
        _ = recorder.take()
        let start = Date()
        var agentCalls = 0
        var steps = 0
        var answer = ""
        var speeds: [Double] = []
        var failure: String?
        var firstPrompt: Int?
        do {
            for try await event in agent.run(messages: [system, .user(prompt)]) {
                switch event {
                case .toolStarted(let call, _):
                    agentCalls += 1
                    print("  call  \(call.name) \(call.arguments.jsonString.prefix(200))")
                case .toolFinished(let message):
                    print("  \(message.isError ? "error" : "result") \(message.text.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(220))")
                case .assistantMessage(let message):
                    if !message.toolCalls.isEmpty {
                        callingSteps += 1
                        if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            spokeBeforeCall += 1
                            if spokeBeforeCall <= 6 { print("    said: \(message.text.prefix(110).replacingOccurrences(of: "\n", with: " "))") }
                        }
                    }
                    steps += 1
                    if !message.reasoning.isEmpty { print("  think (\(message.reasoning.count) chars)") }
                    if let speed = message.stats?.tokensPerSecond { speeds.append(speed) }
                    if firstPrompt == nil { firstPrompt = message.stats?.promptTokens }
                    if message.toolCalls.isEmpty { answer = message.text }
                case .toolsLoaded(let names):
                    let specs = groups.flatMap(\.tools).map(\.spec).filter { names.contains($0.name) }
                    let size = specs.reduce(0) { $0 + $1.functionDeclaration.jsonString.utf8.count } / 4
                    loadedSizes.append(size)
                    print("  loaded \(names.count) tools, about \(size) tokens: \(names.joined(separator: " "))")
                case .textDelta, .reasoningDelta, .finished:
                    break
                }
                peak = max(peak, residentMemory())
            }
        } catch {
            failure = error.localizedDescription
        }
        let elapsed = Date().timeIntervalSince(start)
        let ran = recorder.take()
        print("  answer: \(answer.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(400))")

        var ok = failure == nil && !answer.isEmpty
        if !task.anyTool.isEmpty {
            if !task.anyTool.contains(where: { name in ran.contains { $0.name == name } }) {
                ok = false
                failure = failure ?? "did not use \(task.anyTool.joined(separator: " or "))"
            }
        } else if task.tools.isEmpty {
            if agentCalls > 0 { ok = false; failure = "used tools when none were needed" }
        } else if setup == "shell" && task.shellFree {
            if agentCalls == 0 { ok = false; failure = failure ?? "ran no command" }
        } else {
            for name in task.tools where !ran.contains(where: { $0.name == name }) {
                ok = false
                failure = failure ?? "did not use \(name)"
            }
        }
        if !task.argsAny.isEmpty {
            let all = ran.map { $0.arguments.lowercased() }.joined(separator: " ")
            if !task.argsAny.contains(where: { all.contains($0) }) { ok = false; failure = failure ?? "arguments lack \(task.argsAny[0])" }
        }
        if let expected = task.answer {
            let normalized = answer.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "\u{202F}", with: "")
                .replacingOccurrences(of: "\u{2011}", with: "-").replacingOccurrences(of: "\u{2013}", with: "-").lowercased()
            if !normalized.contains(expected.lowercased()) { ok = false; failure = failure ?? "answer lacks \(expected)" }
        }
        if ok { passed += 1 } else { failures.append("\(index): \(failure ?? "failed")") }
        if let firstPrompt { promptSizes.append(firstPrompt) }
        durations.append(elapsed)
        stepCounts.append(steps)
        let speed = speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)
        print(String(format: "  %@  %.1fs  %d steps  %.0f tok/s  prompt %d%@", ok ? "PASS" : "FAIL", elapsed, steps, speed, firstPrompt ?? 0, failure.map { "  (\($0))" } ?? ""))
    }
}

func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
let meanPrompt = mean(promptSizes.map(Double.init))
print("Spoke before a tool call in \(spokeBeforeCall) of \(callingSteps) calling steps.")
print(String(format: "\n== %@ %@: %d/%d passed, first-step prompt %.0f tokens, %.1fs and %.1f steps per task, peak memory %@",
    repo, setup, passed, total, meanPrompt, mean(durations), mean(stepCounts.map(Double.init)), ModelFit.format(peak)))
if let largest = loadedSizes.max() { print("   connector tools declared at once: up to about \(largest) tokens") }
failures.forEach { print("   fail \($0)") }

if let outPath {
    let line: JSONValue = [
        "model": .string(repo), "setup": .string(setup), "thinking": .string(thinking.rawValue),
        "passed": .int(passed), "total": .int(total), "promptTokens": .int(Int(meanPrompt)),
        "secondsPerTask": .double(mean(durations)), "stepsPerTask": .double(mean(stepCounts.map(Double.init))),
        "failures": .array(failures.map { .string($0) }),
    ]
    let data = (line.jsonString + "\n").data(using: .utf8)!
    if let handle = FileHandle(forWritingAtPath: outPath) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    } else {
        try data.write(to: URL(fileURLWithPath: outPath))
    }
}
exit(0)
