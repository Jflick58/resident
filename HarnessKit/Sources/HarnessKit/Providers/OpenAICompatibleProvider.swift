import Foundation

/// A server that speaks the OpenAI chat completions API: Ollama, LM Studio,
/// llama.cpp, vLLM, or a hosted service.
public struct RemoteEndpoint: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Base URL including the version path, e.g. `http://192.168.1.20:11434/v1`.
    public var baseURL: String
    public var apiKey: String
    public var model: String

    public init(id: UUID = UUID(), name: String, baseURL: String, apiKey: String = "", model: String) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    /// The base URL with a scheme and without a trailing slash, or nil when it is not a usable URL.
    public var normalizedBaseURL: URL? {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return url
    }
}

public struct OpenAICompatibleProvider: ModelProvider {
    public let endpoint: RemoteEndpoint
    private let session: URLSession

    public init(endpoint: RemoteEndpoint, session: URLSession? = nil) {
        self.endpoint = endpoint
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 1800
            self.session = URLSession(configuration: configuration)
        }
    }

    /// Lists the model names the server offers.
    public static func listModels(endpoint: RemoteEndpoint) async throws -> [String] {
        guard let base = endpoint.normalizedBaseURL else {
            throw ProviderError("The server address is not a valid URL.")
        }
        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.timeoutInterval = 10
        if !endpoint.apiKey.isEmpty {
            request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProviderError("The server answered with status \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        return (json["data"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }.sorted()
    }

    public func generate(_ request: GenerationRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await stream(request, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError {
                    continuation.finish(throwing: ProviderError(Self.describe(error, endpoint: endpoint)))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func stream(
        _ request: GenerationRequest, continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation
    ) async throws {
        guard let base = endpoint.normalizedBaseURL else {
            throw ProviderError("The server address is not a valid URL.")
        }
        let url = base.appendingPathComponent("chat/completions")

        // Servers disagree on how thinking is controlled, and reject what they do not
        // know. Try the standard field, then Ollama's, then neither.
        var thinkingStyle = ThinkingStyle.reasoningEffort
        // Some models cannot stop thinking. Asked not to, they think anyway and the
        // server passes it on as part of the answer, marked only by a closing
        // `</think>` (Qwen 3 4B on Ollama). The first reply with thinking off is
        // therefore held until it ends, to see which kind of model this is. One that
        // leaks is from then on asked to think a little, which the server keeps apart.
        var request = request
        let wantsNoThinking = request.options.thinking == .off
        let habit = wantsNoThinking ? ThinkingHabit.known(for: endpoint) : nil
        if habit == .always { request.options.thinking = .low }
        let holdsText = wantsNoThinking && habit == nil
        while true {
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            if !endpoint.apiKey.isEmpty {
                urlRequest.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
            }
            let body = Self.requestBody(request, model: endpoint.model, thinkingStyle: thinkingStyle)
            urlRequest.httpBody = try JSONEncoder().encode(body)

            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError("The server did not return an HTTP response.")
            }
            guard (200..<300).contains(http.statusCode) else {
                var errorText = ""
                for try await line in bytes.lines {
                    errorText += line
                    if errorText.count > 2000 { break }
                }
                if http.statusCode == 400, let next = thinkingStyle.fallback {
                    thinkingStyle = next
                    continue
                }
                let detail = JSONValue(jsonString: errorText)?["error"]?["message"]?.stringValue ?? errorText
                throw ProviderError("The server answered with status \(http.statusCode). \(detail.prefix(300))")
            }

            var parser = StreamParser(holdsText: holdsText)
            for try await line in bytes.lines {
                try Task.checkCancellation()
                for event in parser.consume(line: line) { continuation.yield(event) }
            }
            for event in parser.finish() { continuation.yield(event) }
            if holdsText { ThinkingHabit.record(parser.leakedThinking ? .always : .obeys, for: endpoint) }
            return
        }
    }

    static func describe(_ error: URLError, endpoint: RemoteEndpoint) -> String {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet:
            return "Could not reach \(endpoint.name) at \(endpoint.baseURL). Check that the server is running and on the same network."
        default:
            return error.localizedDescription
        }
    }

    /// Whether a server's model stops thinking when asked to, once that has been seen.
    enum ThinkingHabit: String {
        case obeys, always

        private static func key(_ endpoint: RemoteEndpoint) -> String {
            "thinkingHabit|\(endpoint.normalizedBaseURL?.absoluteString ?? endpoint.baseURL)|\(endpoint.model)"
        }

        static func known(for endpoint: RemoteEndpoint) -> ThinkingHabit? {
            UserDefaults.standard.string(forKey: key(endpoint)).flatMap(ThinkingHabit.init(rawValue:))
        }

        static func record(_ habit: ThinkingHabit, for endpoint: RemoteEndpoint) {
            UserDefaults.standard.set(habit.rawValue, forKey: key(endpoint))
        }
    }

    // MARK: Request

    enum ThinkingStyle {
        /// OpenAI's `reasoning_effort`.
        case reasoningEffort
        /// Ollama's boolean `think`.
        case thinkFlag
        case none

        var fallback: ThinkingStyle? {
            switch self {
            case .reasoningEffort: return .thinkFlag
            case .thinkFlag: return ThinkingStyle.none
            case .none: return nil
            }
        }
    }

    static func requestBody(_ request: GenerationRequest, model: String, thinkingStyle: ThinkingStyle) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(request.messages.map(encode)),
            "stream": true,
            "stream_options": ["include_usage": true],
            // Thinking counts against this limit on most servers, so allow for it on top of the reply.
            "max_tokens": .int(request.options.maxOutputTokens + request.options.thinking.outputAllowance),
            "temperature": .double(request.options.temperature),
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map(\.functionDeclaration))
        }
        switch thinkingStyle {
        case .reasoningEffort:
            body["reasoning_effort"] = .string(request.options.thinking == .off ? "none" : request.options.thinking.rawValue)
        case .thinkFlag:
            body["think"] = .bool(request.options.thinking != .off)
        case .none:
            break
        }
        return .object(body)
    }

    static func encode(_ message: Message) -> JSONValue {
        switch message.role {
        case .system:
            return ["role": "system", "content": .string(message.text)]
        case .user:
            guard !message.images.isEmpty else {
                return ["role": "user", "content": .string(message.text)]
            }
            var parts: [JSONValue] = [["type": "text", "text": .string(message.text)]]
            for image in message.images {
                let dataURL = "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
                parts.append(["type": "image_url", "image_url": ["url": .string(dataURL)]])
            }
            return ["role": "user", "content": .array(parts)]
        case .assistant:
            var object: [String: JSONValue] = ["role": "assistant", "content": .string(message.text)]
            if !message.toolCalls.isEmpty {
                object["tool_calls"] = .array(
                    message.toolCalls.map { call in
                        [
                            "id": .string(call.id), "type": "function",
                            "function": ["name": .string(call.name), "arguments": .string(call.arguments.jsonString)],
                        ]
                    })
            }
            return .object(object)
        case .tool:
            return [
                "role": "tool", "tool_call_id": .string(message.toolCallID ?? ""),
                "content": .string(message.text),
            ]
        }
    }

    // MARK: Response

    /// Turns server-sent event lines into provider events.
    struct StreamParser {
        private struct PartialCall {
            var id = ""
            var name = ""
            var arguments = ""
        }

        private var partialCalls: [Int: PartialCall] = [:]
        private var splitter = ThinkTagSplitter()
        private var finishReason: String?
        private var stats: GenerationStats?
        private var finished = false
        /// When set, the answer's text is kept until the end and looked over for leaked thinking.
        private let holdsText: Bool
        private var held = ""
        /// True once held text turned out to carry thinking in it.
        private(set) var leakedThinking = false

        init(holdsText: Bool = false) { self.holdsText = holdsText }

        mutating func consume(line: String) -> [ProviderEvent] {
            guard line.hasPrefix("data:") else { return [] }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let json = JSONValue(jsonString: payload) else { return [] }

            var events: [ProviderEvent] = []
            if let usage = json["usage"], usage != .null {
                stats = GenerationStats(
                    promptTokens: usage["prompt_tokens"]?.intValue,
                    outputTokens: usage["completion_tokens"]?.intValue)
            }
            guard let choice = json["choices"]?.arrayValue?.first else { return events }
            if let reason = choice["finish_reason"]?.stringValue { finishReason = reason }

            guard let delta = choice["delta"] else { return events }
            let reasoning = delta["reasoning_content"]?.stringValue ?? delta["reasoning"]?.stringValue
            if let reasoning, !reasoning.isEmpty { events.append(.reasoning(reasoning)) }
            if let content = delta["content"]?.stringValue, !content.isEmpty {
                if holdsText {
                    held += content
                } else {
                    for piece in splitter.feed(content) { events.append(Self.event(piece)) }
                }
            }
            for item in delta["tool_calls"]?.arrayValue ?? [] {
                let index = item["index"]?.intValue ?? partialCalls.count
                var partial = partialCalls[index] ?? PartialCall()
                if let id = item["id"]?.stringValue, !id.isEmpty { partial.id = id }
                if let name = item["function"]?["name"]?.stringValue { partial.name += name }
                if let arguments = item["function"]?["arguments"] {
                    // Usually a string fragment; some servers send a whole object.
                    if case .string(let fragment) = arguments {
                        partial.arguments += fragment
                    } else if arguments != .null {
                        partial.arguments = arguments.jsonString
                    }
                }
                partialCalls[index] = partial
            }
            return events
        }

        mutating func finish() -> [ProviderEvent] {
            guard !finished else { return [] }
            finished = true
            var events = splitter.finish().map(Self.event)
            if holdsText, !held.isEmpty {
                if let close = held.range(of: "</think>", options: .backwards) {
                    // Thinking with only its end marked: what comes before is thinking, what comes after the answer.
                    leakedThinking = true
                    let thinking = held[..<close.lowerBound].replacingOccurrences(of: "<think>", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let answer = held[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !thinking.isEmpty { events.append(.reasoning(thinking)) }
                    if !answer.isEmpty { events.append(.text(answer)) }
                } else {
                    events.append(.text(held))
                }
            }

            let calls = partialCalls.keys.sorted().compactMap { index -> ToolCall? in
                guard let partial = partialCalls[index], !partial.name.isEmpty else { return nil }
                let arguments = JSONValue(jsonString: partial.arguments.isEmpty ? "{}" : partial.arguments) ?? .object([:])
                return ToolCall(
                    id: partial.id.isEmpty ? ToolCall.makeID() : partial.id, name: partial.name,
                    arguments: arguments)
            }
            events.append(contentsOf: calls.map(ProviderEvent.toolCall))

            let reason: StopReason
            if !calls.isEmpty {
                reason = .toolCalls
            } else if finishReason == "length" {
                reason = .length
            } else {
                reason = .stop
            }
            events.append(.finished(reason, stats))
            return events
        }

        private static func event(_ piece: ThinkTagSplitter.Piece) -> ProviderEvent {
            switch piece {
            case .text(let text): return .text(text)
            case .reasoning(let text): return .reasoning(text)
            }
        }
    }
}
