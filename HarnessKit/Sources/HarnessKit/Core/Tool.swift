import Foundation

public struct ToolResult: Sendable {
    public var text: String
    public var isError: Bool

    public init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    public static func error(_ text: String) -> ToolResult { ToolResult(text, isError: true) }
}

/// Something the model can call. Tools never throw: a failure is a result the
/// model can read and react to.
public protocol Tool: Sendable {
    var spec: ToolSpec { get }
    /// A short line for the transcript, e.g. `Searched the web for "swift 6"`.
    func summary(for arguments: JSONValue) -> String
    func call(_ arguments: JSONValue) async -> ToolResult
}

extension Tool {
    public func summary(for arguments: JSONValue) -> String { spec.name }
}

/// Identifiers for the tools that ship with the app. Presets refer to tools by
/// these names.
public enum BuiltInTool: String, Codable, CaseIterable, Sendable, Identifiable {
    case webSearch = "web_search"
    case fetchPage = "fetch_page"
    case runJavaScript = "run_javascript"
    case saveMemory = "save_memory"
    case skills = "use_skill"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .webSearch: return "Web Search"
        case .fetchPage: return "Read Web Pages"
        case .runJavaScript: return "Run Code"
        case .saveMemory: return "Memory"
        case .skills: return "Skills"
        }
    }

    public var detail: String {
        switch self {
        case .webSearch: return "Searches DuckDuckGo from this device. Only the query leaves it."
        case .fetchPage: return "Opens a page and reads the relevant parts."
        case .runJavaScript: return "Runs JavaScript in a sandbox for maths and data work."
        case .saveMemory: return "Remembers facts you share across chats."
        case .skills: return "Loads your instructions for a task when it comes up."
        }
    }

    public var symbol: String {
        switch self {
        case .webSearch: return "magnifyingglass"
        case .fetchPage: return "doc.text"
        case .runJavaScript: return "chevron.left.forwardslash.chevron.right"
        case .saveMemory: return "brain"
        case .skills: return "book.closed"
        }
    }

    /// Whether using the tool sends anything off the device.
    public var usesNetwork: Bool {
        switch self {
        case .webSearch, .fetchPage: return true
        case .runJavaScript, .saveMemory, .skills: return false
        }
    }
}
