import Foundation

/// A connector the user added: an MCP server, the tools it offered when last
/// asked, and which of them are switched off.
public struct MCPServerConfig: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var url: String
    /// What the service is for, in a few words, when known.
    public var summary: String?
    /// The server's own notes on how to use its tools, shown to the model when it opens the connector.
    public var instructions: String?
    public var tools: [MCPToolInfo]
    /// Names of tools the user has turned off.
    public var disabledTools: [String]
    /// A client ID registered by hand, for services where apps cannot register themselves.
    public var clientID: String?
    /// Permissions to ask for at sign-in, when not everything the server offers.
    public var scopes: [String]?
    /// True when sign-in is by a code the user types at the service's site, which needs no client secret.
    public var signsInWithCode: Bool?
    /// True when the server wants a sign-in that has not happened or has lapsed.
    public var needsSignIn: Bool
    /// True once the user has signed in, so the screen can offer signing out.
    public var isSignedIn: Bool

    public init(
        id: UUID = UUID(), name: String, url: String, summary: String? = nil, tools: [MCPToolInfo] = [], disabledTools: [String] = [],
        clientID: String? = nil, scopes: [String]? = nil, needsSignIn: Bool = false, isSignedIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.summary = summary
        self.tools = tools
        self.disabledTools = disabledTools
        self.clientID = clientID
        self.scopes = scopes
        self.needsSignIn = needsSignIn
        self.isSignedIn = isSignedIn
    }

    public var enabledTools: [MCPToolInfo] { tools.filter { !disabledTools.contains($0.name) } }

    /// A usable address from what someone typed: adds https and rejects anything that is not a web address.
    public static func normalizedURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// Where the service sends the browser after sign-in. Google gives each iOS
    /// client its own address, made from the client ID; everything else uses the app's.
    public static func redirectURI(clientID: String?, default fallback: String) -> String {
        let suffix = ".apps.googleusercontent.com"
        guard let clientID, clientID.hasSuffix(suffix) else { return fallback }
        return "com.googleusercontent.apps.\(clientID.dropLast(suffix.count)):/oauth2redirect"
    }

    /// The prefix that keeps this server's tool names apart from every other tool's.
    public var toolPrefix: String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let joined = String(slug).split(separator: "_").joined(separator: "_")
        let short = String((joined.isEmpty ? "server" : joined).prefix(20))
        return short.hasSuffix("_") ? String(short.dropLast()) : short
    }

    /// The name the model sees for one of this server's tools.
    public func exposedName(for tool: String) -> String {
        let cleaned = String(tool.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
        let name = cleaned.lowercased().hasPrefix(toolPrefix) ? cleaned : "\(toolPrefix)_\(cleaned)"
        return String(name.prefix(64))
    }
}

/// A live link to one MCP server: keeps the session and the sign-in, and renews
/// the access token when it runs out.
public actor MCPConnection {
    public let serverURL: URL
    private let client: MCPClient
    private let oauth: OAuthFlow
    private var credentials: MCPCredentials?
    private let onCredentialsChange: @Sendable (MCPCredentials?) -> Void

    public init(
        url: URL, credentials: MCPCredentials?, session: URLSession = .shared,
        onCredentialsChange: @escaping @Sendable (MCPCredentials?) -> Void = { _ in }
    ) {
        serverURL = url
        client = MCPClient(url: url, session: session)
        oauth = OAuthFlow(session: session)
        self.credentials = credentials
        self.onCredentialsChange = onCredentialsChange
    }

    public var isSignedIn: Bool { credentials != nil }
    public var serverName: String? { get async { await client.serverName } }
    public var instructions: String? { get async { await client.instructions } }

    /// Replaces the sign-in, or removes it with nil.
    public func setCredentials(_ credentials: MCPCredentials?) {
        self.credentials = credentials
        onCredentialsChange(credentials)
    }

    public func listTools() async throws -> [MCPToolInfo] {
        try await authorized { try await self.client.listTools(token: $0) }
    }

    public func callTool(_ name: String, arguments: JSONValue) async throws -> ToolResult {
        try await authorized { try await self.client.callTool(name, arguments: arguments, token: $0) }
    }

    /// The current access token, renewed first if it has run out. For calling the
    /// service's own API beside its MCP server, as the code workspace does with GitHub.
    public func accessToken() async -> String? {
        if let credentials, credentials.tokens.isExpired(), credentials.tokens.refreshToken != nil { _ = try? await renew() }
        return credentials?.tokens.accessToken
    }

    /// Runs a request with the current token. A token the server no longer
    /// accepts is renewed once; if that fails, the user has to sign in again.
    private func authorized<T: Sendable>(_ operation: (String?) async throws -> T) async throws -> T {
        if let credentials, credentials.tokens.isExpired(), credentials.tokens.refreshToken != nil {
            _ = try? await renew()
        }
        do {
            return try await operation(credentials?.tokens.accessToken)
        } catch MCPError.unauthorized(let challenge) {
            guard credentials?.tokens.refreshToken != nil, (try? await renew()) != nil else {
                throw MCPError.needsSignIn(challenge: challenge)
            }
            do {
                return try await operation(credentials?.tokens.accessToken)
            } catch MCPError.unauthorized(let challenge) {
                throw MCPError.needsSignIn(challenge: challenge)
            }
        }
    }

    private func renew() async throws -> OAuthTokens {
        guard var current = credentials else { throw OAuthError("Not signed in.") }
        current.tokens = try await oauth.refresh(current)
        setCredentials(current)
        return current.tokens
    }
}

/// One tool of an MCP server, as the agent sees it.
public struct MCPTool: Tool {
    /// Results longer than this are cut, so one large answer cannot fill a small model's context.
    public static let resultLimit = 6000
    /// Plain text, such as a file, is passed on whole up to this length. The agent shows it to the model a part at a time.
    public static let textLimit = 60000

    public var connection: MCPConnection
    public var serverName: String
    public var info: MCPToolInfo
    public var exposedName: String

    public init(connection: MCPConnection, server: MCPServerConfig, info: MCPToolInfo) {
        self.connection = connection
        serverName = server.name
        self.info = info
        exposedName = server.exposedName(for: info.name)
    }

    public var spec: ToolSpec {
        Self.modelSpec(name: exposedName, serverName: serverName, info: info)
    }

    /// The tool as the model is shown it: named after its server, with the
    /// description and parameter schema cut down to size.
    public static func modelSpec(name: String, serverName: String, info: MCPToolInfo) -> ToolSpec {
        var description = SchemaTrim.shorten(info.description, to: SchemaTrim.descriptionLimit)
        if description.isEmpty { description = info.title ?? info.name }
        return ToolSpec(name: name, description: "[\(serverName)] \(description)", parameters: SchemaTrim.parameters(info.inputSchema))
    }

    /// The tool's name in plain words, e.g. "list issues".
    public static func readableName(_ info: MCPToolInfo) -> String {
        if let title = info.title, !title.isEmpty { return title }
        return info.name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    }

    public func summary(for arguments: JSONValue) -> String { "\(serverName): \(Self.readableName(info))" }

    public func call(_ arguments: JSONValue) async -> ToolResult {
        do {
            var result = try await connection.callTool(info.name, arguments: arguments.objectValue == nil ? [:] : arguments)
            result.text = ResultFit.isStructured(result.text)
                ? ResultFit.fit(result.text, limit: Self.resultLimit) : ResultFit.fit(result.text, limit: Self.textLimit)
            return result
        } catch MCPError.needsSignIn {
            return .error(
                "\(serverName) needs the user to sign in again. Tell the user to open Settings > Connectors > \(serverName) and sign in.")
        } catch {
            return .error("\(serverName) failed: \(error.localizedDescription)")
        }
    }
}
