import Foundation

public enum Role: String, Codable, Sendable {
    case system, user, assistant, tool
}

/// A tool invocation requested by the model.
public struct ToolCall: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: JSONValue

    public init(id: String = ToolCall.makeID(), name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    public static func makeID() -> String {
        "call_" + UUID().uuidString.prefix(8).lowercased()
    }

    /// Name a provider gives a call it saw the model attempt but could not read.
    /// The agent answers it with an error so the model can try again, instead
    /// of the turn ending with nothing.
    public static let unreadableName = "unreadable_tool_call"

    public static func unreadable(reason: String) -> ToolCall {
        ToolCall(name: unreadableName, arguments: ["reason": .string(reason)])
    }
}

/// An image attached to a user message, stored as encoded bytes (JPEG or PNG).
public struct ImageAttachment: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var data: Data
    public var mimeType: String
    /// Text read from the image on the device, for models that cannot see it.
    public var recognizedText: String?

    public init(id: UUID = UUID(), data: Data, mimeType: String = "image/jpeg", recognizedText: String? = nil) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
        self.recognizedText = recognizedText
    }
}

public struct GenerationStats: Codable, Hashable, Sendable {
    public var promptTokens: Int?
    public var outputTokens: Int?
    public var tokensPerSecond: Double?
    public var timeToFirstToken: Double?

    public init(
        promptTokens: Int? = nil, outputTokens: Int? = nil, tokensPerSecond: Double? = nil,
        timeToFirstToken: Double? = nil
    ) {
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.tokensPerSecond = tokensPerSecond
        self.timeToFirstToken = timeToFirstToken
    }
}

public struct Message: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var role: Role
    public var text: String
    /// The model's thinking for this turn. Shown in the UI, never replayed to the model.
    public var reasoning: String
    public var reasoningSeconds: Double?
    /// Tool calls made by an assistant message.
    public var toolCalls: [ToolCall]
    /// For a tool message: the call it answers.
    public var toolCallID: String?
    public var toolName: String?
    public var isError: Bool
    public var images: [ImageAttachment]
    /// Documents attached to a user message. Optional so chats saved before documents existed still open.
    public var documents: [DocumentAttachment]?
    public var stats: GenerationStats?
    public var date: Date

    public init(
        id: UUID = UUID(), role: Role, text: String, reasoning: String = "",
        reasoningSeconds: Double? = nil, toolCalls: [ToolCall] = [], toolCallID: String? = nil,
        toolName: String? = nil, isError: Bool = false, images: [ImageAttachment] = [],
        stats: GenerationStats? = nil, date: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.reasoningSeconds = reasoningSeconds
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.isError = isError
        self.images = images
        self.stats = stats
        self.date = date
    }

    public static func system(_ text: String) -> Message { Message(role: .system, text: text) }
    public static func user(_ text: String, images: [ImageAttachment] = [], documents: [DocumentAttachment] = []) -> Message {
        var message = Message(role: .user, text: text, images: images)
        message.documents = documents.isEmpty ? nil : documents
        return message
    }
    public static func assistant(_ text: String, toolCalls: [ToolCall] = []) -> Message {
        Message(role: .assistant, text: text, toolCalls: toolCalls)
    }
    public static func tool(_ text: String, call: ToolCall, isError: Bool = false) -> Message {
        Message(
            role: .tool, text: text, toolCallID: call.id, toolName: call.name, isError: isError)
    }
}

/// How hard the model should think before answering.
public enum ThinkingLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, low, medium, high

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// Extra output tokens to allow for thinking on servers that count it against the reply limit.
    public var outputAllowance: Int {
        switch self {
        case .off: return 0
        case .low: return 1024
        case .medium: return 2048
        case .high: return 4096
        }
    }

    /// Token budget for thinking, for runtimes that cap it.
    public var tokenBudget: Int? {
        switch self {
        case .off: return 0
        case .low: return 512
        case .medium: return 2048
        case .high: return nil
        }
    }
}

public struct GenerationOptions: Codable, Hashable, Sendable {
    public var maxOutputTokens: Int
    public var temperature: Double
    public var topP: Double
    /// Above 1 discourages repeating recent words. Nil leaves repetition alone.
    public var repetitionPenalty: Double?
    public var thinking: ThinkingLevel
    /// True for a request that nothing will follow: a chat's title, a fact for memory. A provider
    /// that keeps a model's reading of a chat between requests leaves that as it is, and the chat
    /// carries on from it afterwards. Nil means false.
    public var standsAlone: Bool?

    public init(
        maxOutputTokens: Int = 2048, temperature: Double = 0.6, topP: Double = 0.95, repetitionPenalty: Double? = nil,
        thinking: ThinkingLevel = .low, standsAlone: Bool? = nil
    ) {
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
        self.thinking = thinking
        self.standsAlone = standsAlone
    }
}

/// How a model picks its words. Each model has its own best values, so these
/// belong to the model; an agent's style only nudges them.
public struct SamplingSettings: Codable, Hashable, Sendable {
    public var temperature: Double
    public var topP: Double
    public var repetitionPenalty: Double?

    public init(temperature: Double = 0.6, topP: Double = 0.95, repetitionPenalty: Double? = nil) {
        self.temperature = temperature
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
    }

    /// Used for a model that does not say what it prefers.
    public static let standard = SamplingSettings()

    /// The values a model's maker recommends, from its generation_config.json.
    /// Anything the file leaves out keeps the standard value.
    public init(generationConfig: JSONValue?) {
        self.init()
        guard let config = generationConfig, config["do_sample"]?.boolValue != false else { return }
        if let value = config["temperature"]?.doubleValue, value >= 0, value <= 2 { temperature = value }
        if let value = config["top_p"]?.doubleValue, value > 0, value <= 1 { topP = value }
        if let value = config["repetition_penalty"]?.doubleValue, value >= 1, value <= 2, value != 1 {
            repetitionPenalty = value
        }
    }
}
