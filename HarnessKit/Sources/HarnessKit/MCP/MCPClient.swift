import Foundation

// A client for Model Context Protocol servers over Streamable HTTP: one POST
// per JSON-RPC message, answered either as JSON or as a short event stream.

public enum MCPError: LocalizedError, Sendable, Equatable {
    /// The server answered 401. `challenge` is its WWW-Authenticate header.
    case unauthorized(challenge: String?)
    /// Signing in (again) is the only way forward.
    case needsSignIn(challenge: String?)
    /// The server answered a request with a JSON-RPC error.
    case server(String)
    /// The server could not be reached or answered something that is not MCP.
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized, .needsSignIn: return "This connector needs you to sign in."
        case .server(let message), .transport(let message): return message
        }
    }
}

/// A tool as the server describes it.
public struct MCPToolInfo: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var title: String?
    public var description: String
    public var inputSchema: JSONValue

    public var id: String { name }

    public init(name: String, title: String? = nil, description: String, inputSchema: JSONValue) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// Splits a `text/event-stream` body into the data of each event.
public struct SSEParser: Sendable {
    private var data: [String] = []

    public init() {}

    /// Feeds one line, without its line ending. Returns an event's data when the line completes one.
    public mutating func feed(_ line: String) -> String? {
        if line.isEmpty {
            defer { data = [] }
            return data.isEmpty ? nil : data.joined(separator: "\n")
        }
        if line.hasPrefix("data:") {
            var value = line.dropFirst(5)
            if value.first == " " { value = value.dropFirst() }
            data.append(String(value))
        }
        // Comments and the event, id and retry fields carry nothing this client needs.
        return nil
    }

    /// The event still open when the stream ends, if any.
    public mutating func finish() -> String? { feed("") }
}

public actor MCPClient {
    public static let protocolVersion = "2025-06-18"

    public let url: URL
    private let session: URLSession
    private var sessionID: String?
    private var negotiatedVersion: String?
    private var nextID = 1

    /// What the server calls itself, known after the first request.
    public private(set) var serverName: String?
    /// The server's own notes on how to use its tools, when it gives any.
    public private(set) var instructions: String?

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    /// Lists every tool, following the server's paging.
    public func listTools(token: String?) async throws -> [MCPToolInfo] {
        var tools: [MCPToolInfo] = []
        var cursor: String?
        repeat {
            let params: JSONValue = cursor.map { ["cursor": .string($0)] } ?? [:]
            let result = try await request("tools/list", params: params, token: token)
            for tool in result["tools"]?.arrayValue ?? [] {
                guard let name = tool["name"]?.stringValue else { continue }
                tools.append(
                    MCPToolInfo(
                        name: name, title: tool["title"]?.stringValue ?? tool["annotations"]?["title"]?.stringValue,
                        description: tool["description"]?.stringValue ?? "",
                        inputSchema: tool["inputSchema"] ?? ["type": "object", "properties": [:]]))
            }
            cursor = result["nextCursor"]?.stringValue
        } while cursor != nil && tools.count < 500
        return tools
    }

    /// Calls a tool and returns what it said as text.
    public func callTool(_ name: String, arguments: JSONValue, token: String?) async throws -> ToolResult {
        let result = try await request("tools/call", params: ["name": .string(name), "arguments": arguments], token: token)
        var parts: [String] = []
        for item in result["content"]?.arrayValue ?? [] {
            switch item["type"]?.stringValue {
            case "text": if let text = item["text"]?.stringValue { parts.append(text) }
            case "resource":
                if let text = item["resource"]?["text"]?.stringValue { parts.append(text) }
            case "resource_link":
                if let uri = item["uri"]?.stringValue { parts.append(uri) }
            case let other?: parts.append("[\(other) content left out]")
            case nil: break
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"], structured != .null {
            parts.append(structured.jsonString)
        }
        let text = parts.joined(separator: "\n")
        return ToolResult(text.isEmpty ? "(no output)" : text, isError: result["isError"]?.boolValue ?? false)
    }

    /// Sends a request, starting the session first if there is none. A session the
    /// server has forgotten is started again once.
    private func request(_ method: String, params: JSONValue, token: String?) async throws -> JSONValue {
        for attempt in 0..<2 {
            if negotiatedVersion == nil { try await initialize(token: token) }
            do {
                return try await send(method, params: params, token: token)
            } catch SessionExpired.expired where attempt == 0 {
                sessionID = nil
                negotiatedVersion = nil
            }
        }
        throw MCPError.transport("The server keeps ending the session.")
    }

    private func initialize(token: String?) async throws {
        let result = try await send(
            "initialize",
            params: [
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": [:],
                "clientInfo": ["name": "Resident", "version": "0.1"],
            ], token: token)
        negotiatedVersion = result["protocolVersion"]?.stringValue ?? Self.protocolVersion
        serverName = result["serverInfo"]?["title"]?.stringValue ?? result["serverInfo"]?["name"]?.stringValue
        instructions = result["instructions"]?.stringValue
        _ = try await send("notifications/initialized", params: nil, token: token, isNotification: true)
    }

    private enum SessionExpired: Error { case expired }

    private func send(
        _ method: String, params: JSONValue?, token: String?, isNotification: Bool = false
    ) async throws -> JSONValue {
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { message["params"] = params }
        let id = nextID
        if !isNotification {
            message["id"] = .int(id)
            nextID += 1
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.httpBody = Data(JSONValue.object(message).jsonString.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let negotiatedVersion { request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version") }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw MCPError.transport("Could not reach the server: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.transport("The server did not answer over HTTP.")
        }
        if http.statusCode == 401 {
            throw MCPError.unauthorized(challenge: http.value(forHTTPHeaderField: "WWW-Authenticate"))
        }
        if http.statusCode == 404, sessionID != nil { throw SessionExpired.expired }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: try await Self.collect(bytes, limit: 2000), as: UTF8.self)
            // Google refuses with a status and a header and still sends the answer as the
            // body, so the body says why only when it is an error or not an answer at all.
            let parsed = JSONValue(jsonString: body)
            let detail =
                parsed?["error"]?["message"]?.stringValue
                ?? http.value(forHTTPHeaderField: "WWW-Authenticate")
                ?? (parsed?["result"] != nil || body.contains("\"result\"")
                    ? "It gave no reason. The account or the app may not be allowed to use this service."
                    : body.prefix(200).description)
            throw MCPError.transport("The server answered \(http.statusCode). \(detail)".trimmingCharacters(in: .whitespaces))
        }
        if let newSession = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = newSession }
        if isNotification { return .null }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("text/event-stream") {
            // Read events until the answer to this request arrives; anything else
            // on the stream (progress, log messages, server requests) is skipped.
            var parser = SSEParser()
            var line: [UInt8] = []
            func match(_ event: String?) throws -> JSONValue? {
                guard let event, let message = JSONValue(jsonString: event) else { return nil }
                return try Self.answer(in: message, id: id)
            }
            do {
                for try await byte in bytes {
                    guard byte == 0x0A else {
                        line.append(byte)
                        continue
                    }
                    if line.last == 0x0D { line.removeLast() }
                    let event = parser.feed(String(decoding: line, as: UTF8.self))
                    line = []
                    if let result = try match(event) { return result }
                }
            } catch let error as MCPError {
                throw error
            } catch {
                throw MCPError.transport("The connection dropped: \(error.localizedDescription)")
            }
            if !line.isEmpty { _ = parser.feed(String(decoding: line, as: UTF8.self)) }
            if let result = try match(parser.finish()) { return result }
            throw MCPError.transport("The server closed the connection without answering.")
        }

        let body = try await Self.collect(bytes, limit: 8_000_000)
        guard let message = JSONValue(jsonString: String(decoding: body, as: UTF8.self)) else {
            throw MCPError.transport("The server's answer was not JSON. Check that the address is an MCP endpoint.")
        }
        for candidate in message.arrayValue ?? [message] {
            if let result = try Self.answer(in: candidate, id: id) { return result }
        }
        throw MCPError.transport("The server's answer did not match the request.")
    }

    /// The result of the response with this id; nil when the message is something else.
    private static func answer(in message: JSONValue, id: Int) throws -> JSONValue? {
        guard message["id"]?.intValue == id, message["method"] == nil else { return nil }
        if let error = message["error"] {
            throw MCPError.server(error["message"]?.stringValue ?? "The server reported an error.")
        }
        return message["result"] ?? .null
    }

    private static func collect(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {
            throw MCPError.transport("The connection dropped: \(error.localizedDescription)")
        }
        return data
    }
}
