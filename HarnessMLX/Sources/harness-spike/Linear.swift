import Foundation
import HarnessKit

// A stand-in for Linear's MCP server: its real tool names, descriptions and
// parameter schemas (linear-tools.json, 27 of them, about 13,000 tokens),
// answering from canned data. It is here to see how a small model copes with
// one large connector.

struct LinearTool: Tool {
    var info: ToolSpec
    var recorder: CallRecorder?
    /// Definitions as the server sends them, to compare against the trimmed form.
    var untrimmed = false

    /// Named and described the way the app presents an MCP tool.
    var spec: ToolSpec {
        if untrimmed {
            return ToolSpec(
                name: "linear_" + info.name, description: "[Linear] " + String(info.description.prefix(1200)), parameters: info.parameters)
        }
        return MCPTool.modelSpec(
            name: "linear_" + info.name, serverName: "Linear",
            info: MCPToolInfo(name: info.name, description: info.description, inputSchema: info.parameters))
    }

    func call(_ arguments: JSONValue) async -> ToolResult {
        recorder?.record(spec.name, arguments)
        let values = arguments.objectValue ?? [:]
        let allowed = info.parameters["properties"]?.objectValue ?? [:]
        for key in values.keys where allowed[key] == nil {
            return .error("Unrecognized key: \(key).")
        }
        for name in info.parameters["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where values[name] == nil {
            return .error("Missing required argument: \(name).")
        }
        func text(_ key: String) -> String { values[key]?.stringValue ?? "" }
        switch info.name {
        case "list_issues":
            return ToolResult(
                """
                ENG-412  Fix login crash on iOS 27  status: In Progress  priority: Urgent  assignee: me  team: Engineering
                ENG-431  Add export to CSV  status: Todo  priority: Medium  assignee: me  team: Engineering
                hasNextPage: false
                """)
        case "get_issue":
            guard text("id").uppercased().contains("412") || text("id").uppercased().contains("431") else {
                return .error("Issue not found: \(text("id")).")
            }
            return text("id").contains("412")
                ? ToolResult("ENG-412  Fix login crash on iOS 27\nstatus: In Progress  priority: Urgent  assignee: Justin  team: Engineering\ndescription: The app crashes on launch after signing in with a passkey.")
                : ToolResult("ENG-431  Add export to CSV\nstatus: Todo  priority: Medium  assignee: Justin  team: Engineering\ndescription: Customers want to export reports.")
        case "save_issue":
            if text("id").isEmpty {
                guard !text("team").isEmpty, !text("title").isEmpty else { return .error("team and title are required when creating an issue.") }
                return ToolResult("Created ENG-440  \(text("title"))  team: \(text("team"))")
            }
            return ToolResult("Updated \(text("id")).")
        case "list_comments":
            guard !text("issueId").isEmpty else { return .error("Provide exactly one parent, such as issueId.") }
            return ToolResult("Dana Whit (2 days ago): Customers want semicolon separators too.\nBen Ortiz (yesterday): I can take the date formatting.")
        case "save_comment":
            guard !text("issueId").isEmpty || !text("parentId").isEmpty else { return .error("Provide exactly one parent, such as issueId.") }
            return ToolResult("Comment added.")
        case "list_projects":
            return ToolResult("Onboarding Revamp  status: In Progress  health: atRisk  target: 2026-12-01\nBilling v2  status: In Progress  health: onTrack  target: 2027-01-15")
        case "get_project":
            return ToolResult("Billing v2  status: In Progress  health: onTrack  lead: Dana Whit  milestones: Private beta (2026-12-10), General release (2027-01-15)")
        case "list_milestones":
            return ToolResult("Private beta  target: 2026-12-10\nGeneral release  target: 2027-01-15")
        case "list_teams": return ToolResult("Engineering (ENG)\nDesign (DES)")
        case "get_team": return ToolResult("Design (DES)  members: Aiko Tanaka, Ben Ortiz")
        case "list_users":
            return ToolResult(
                text("team").lowercased().hasPrefix("des")
                    ? "Aiko Tanaka <aiko@acme.example>\nBen Ortiz <ben@acme.example>"
                    : "Aiko Tanaka <aiko@acme.example>\nBen Ortiz <ben@acme.example>\nDana Whit <dana@acme.example>\nJustin <justin@acme.example>")
        case "get_user": return ToolResult("Justin <justin@acme.example>  teams: Engineering")
        case "list_issue_statuses": return ToolResult("Backlog, Todo, In Progress, In Review, Done, Canceled")
        case "list_cycles": return ToolResult("Cycle 31  2026-11-09 to 2026-11-22  current")
        default: return ToolResult("No results.")
        }
    }
}

func loadLinearTools(recorder: CallRecorder) -> [LinearTool] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("linear-tools.json")
    guard let data = try? Data(contentsOf: url), let specs = try? JSONDecoder().decode([ToolSpec].self, from: data) else {
        print("Could not read \(url.path)")
        exit(2)
    }
    return specs.map { LinearTool(info: $0, recorder: recorder) }
}

let linearTasks: [Task_] = [
    .init(prompt: "What Linear issues are assigned to me?", tools: ["linear_list_issues"], answer: "ENG-412"),
    .init(prompt: "In Linear, what is the status of issue ENG-412?", anyTool: ["linear_get_issue", "linear_list_issues"], answer: "in progress"),
    .init(prompt: "Create a Linear issue in the Engineering team titled \"Update privacy policy link\".", tools: ["linear_save_issue"], argsAny: ["privacy policy"]),
    .init(prompt: "Add a comment to Linear issue ENG-412 saying the fix is ready for review.", tools: ["linear_save_comment"], argsAny: ["ready for review"]),
    .init(prompt: "What are the latest comments on ENG-431 in Linear?", tools: ["linear_list_comments"], answer: "semicolon"),
    .init(prompt: "Which projects do we have in Linear, and which one is at risk?", tools: ["linear_list_projects"], answer: "onboarding"),
    // Linear is not named: the model has to open it itself.
    .init(prompt: "What tickets are assigned to me at work?", tools: ["linear_list_issues"], answer: "ENG-412"),
    .init(prompt: "Who is on the Design team in Linear?", anyTool: ["linear_list_users", "linear_get_team"], answer: "aiko"),
    .init(prompt: "Move ENG-431 to Done in Linear.", tools: ["linear_save_issue"], argsAny: ["done"]),
    .init(prompt: "What milestones does the Billing v2 project have in Linear?", anyTool: ["linear_list_milestones", "linear_get_project"], answer: "beta"),
    // Other connectors still have to work alongside.
    .init(prompt: "What's the weather in Lisbon right now?", tools: ["weather_current"], answer: "19"),
    .init(prompt: "What is the capital of Australia?", answer: "canberra"),
]
