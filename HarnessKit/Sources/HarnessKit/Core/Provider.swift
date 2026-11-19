import Foundation

/// The JSON Schema description of a tool, as sent to a model.
public struct ToolSpec: Codable, Hashable, Sendable {
    public var name: String
    public var description: String
    /// JSON Schema for the arguments object.
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    /// OpenAI-style function declaration, which is also what chat templates expect.
    public var functionDeclaration: JSONValue {
        [
            "type": "function",
            "function": [
                "name": .string(name),
                "description": .string(description),
                "parameters": parameters,
            ],
        ]
    }
}

public struct GenerationRequest: Sendable {
    public var messages: [Message]
    /// Tools declared to the model through the provider's own tool mechanism.
    public var tools: [ToolSpec]
    /// Tools the model may call this step, including ones it was told about in
    /// the conversation rather than through `tools`. Providers that constrain
    /// decoding admit calls to these. Nil means the same as `tools`.
    public var callableTools: [ToolSpec]?
    public var options: GenerationOptions
    /// The instructions with nothing in them about tools, for a provider that
    /// answers a request without any. Nil when the caller has none to offer.
    public var plainInstructions: String?

    public init(
        messages: [Message], tools: [ToolSpec] = [], callableTools: [ToolSpec]? = nil,
        options: GenerationOptions = .init()
    ) {
        self.messages = messages
        self.tools = tools
        self.callableTools = callableTools
        self.options = options
    }
}

public enum StopReason: String, Codable, Sendable {
    /// The model finished its turn.
    case stop
    /// The output token limit cut the turn short.
    case length
    /// The model asked for tools.
    case toolCalls
    case cancelled
    /// The turn used every step it had, and the model was made to answer with work still to do.
    /// The same turn can be carried on.
    case steps
}

public enum ProviderEvent: Sendable {
    case text(String)
    case reasoning(String)
    case toolCall(ToolCall)
    case finished(StopReason, GenerationStats?)
}

/// One model behind a uniform streaming interface: on-device MLX, a remote
/// OpenAI-compatible server, or a scripted stand-in for tests and previews.
public protocol ModelProvider: Sendable {
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<ProviderEvent, Error>
}

/// The model was stopped from outside while it was generating: on a phone,
/// by iOS withdrawing the graphics processor from an app that is not on screen.
/// What was written so far is kept, and the turn can be carried on.
public struct ModelStoppedError: LocalizedError, Sendable {
    public var detail: String
    public init(_ detail: String) { self.detail = detail }
    public var errorDescription: String? { "The model was stopped before it finished. \(detail)" }
}

public struct ProviderError: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
