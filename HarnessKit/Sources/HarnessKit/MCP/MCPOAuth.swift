import CryptoKit
import Foundation

// Signing in to an MCP server, following the MCP authorization rules: find the
// server's authorization server (RFC 9728, RFC 8414), register this app with it
// if needed (RFC 7591), then the authorization code flow with PKCE, naming the
// MCP server as the resource the token is for (RFC 8707).

/// Where and how to sign in for one MCP server.
public struct OAuthServerInfo: Codable, Hashable, Sendable {
    /// The MCP server's own identifier, sent as `resource`.
    public var resource: String
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var registrationEndpoint: URL?
    public var scopes: [String]

    public init(
        resource: String, authorizationEndpoint: URL, tokenEndpoint: URL, registrationEndpoint: URL? = nil,
        scopes: [String] = []
    ) {
        self.resource = resource
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.scopes = scopes
    }
}

/// This app as the authorization server knows it.
public struct OAuthClientRegistration: Codable, Hashable, Sendable {
    public var clientID: String
    public var clientSecret: String?

    public init(clientID: String, clientSecret: String? = nil) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

public struct OAuthTokens: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// True when the token is past, or within a minute of, its expiry.
    public func isExpired(at date: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(date) < 60
    }
}

/// Everything kept for one signed-in server. Stored in the Keychain.
public struct MCPCredentials: Codable, Hashable, Sendable {
    public var server: OAuthServerInfo
    public var client: OAuthClientRegistration
    public var tokens: OAuthTokens

    public init(server: OAuthServerInfo, client: OAuthClientRegistration, tokens: OAuthTokens) {
        self.server = server
        self.client = client
        self.tokens = tokens
    }
}

public struct OAuthError: LocalizedError, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct OAuthFlow: Sendable {
    public var session: URLSession
    public var clientName: String

    public init(session: URLSession = .shared, clientName: String = "Resident") {
        self.session = session
        self.clientName = clientName
    }

    // MARK: Discovery

    /// Reads `resource_metadata` and `scope` out of a WWW-Authenticate header.
    public static func challenge(_ header: String?) -> (resourceMetadata: URL?, scope: String?) {
        guard let header else { return (nil, nil) }
        func parameter(_ name: String) -> String? {
            guard let range = header.range(of: "\(name)=", options: .caseInsensitive) else { return nil }
            let rest = header[range.upperBound...]
            if rest.first == "\"" {
                return rest.dropFirst().split(separator: "\"", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
            }
            return rest.split(whereSeparator: { $0 == "," || $0 == " " }).first.map(String.init)
        }
        return (parameter("resource_metadata").flatMap { URL(string: $0) }, parameter("scope"))
    }

    /// Well-known addresses to try for a document about `url`, most specific first.
    static func wellKnown(_ name: String, for url: URL, openIDSuffix: Bool = false) -> [URL] {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
        components.query = nil
        components.fragment = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        var candidates: [String] = []
        if !path.isEmpty { candidates.append("/.well-known/\(name)\(path)") }
        if openIDSuffix, !path.isEmpty { candidates.append("\(path)/.well-known/\(name)") }
        candidates.append("/.well-known/\(name)")
        return candidates.compactMap {
            components.path = $0
            return components.url
        }
    }

    private func json(at url: URL) async -> JSONValue? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let value = JSONValue(jsonString: String(decoding: data, as: UTF8.self)), value.objectValue != nil
        else { return nil }
        return value
    }

    /// Works out where to sign in for the MCP server at `serverURL`.
    public func discover(serverURL: URL, challenge header: String?) async throws -> OAuthServerInfo {
        let challenge = Self.challenge(header)
        var resource = serverURL.absoluteString
        var scopes = challenge.scope?.split(separator: " ").map(String.init)
        // Servers from before protected-resource metadata are their own authorization server.
        var authorizationServer = URL(string: "/", relativeTo: serverURL)?.absoluteURL ?? serverURL

        let metadataURLs = (challenge.resourceMetadata.map { [$0] } ?? []) + Self.wellKnown("oauth-protected-resource", for: serverURL)
        for url in metadataURLs {
            guard let metadata = await json(at: url) else { continue }
            if let declared = metadata["resource"]?.stringValue { resource = declared }
            if let first = metadata["authorization_servers"]?.arrayValue?.first?.stringValue, let url = URL(string: first) {
                authorizationServer = url
            }
            if scopes == nil {
                scopes = metadata["scopes_supported"]?.arrayValue?.compactMap(\.stringValue)
            }
            break
        }

        let candidates =
            Self.wellKnown("oauth-authorization-server", for: authorizationServer)
            + Self.wellKnown("openid-configuration", for: authorizationServer, openIDSuffix: true)
        for url in candidates {
            guard let metadata = await json(at: url),
                let authorize = metadata["authorization_endpoint"]?.stringValue.flatMap({ URL(string: $0) }),
                let token = metadata["token_endpoint"]?.stringValue.flatMap({ URL(string: $0) })
            else { continue }
            if let methods = metadata["code_challenge_methods_supported"]?.arrayValue?.compactMap(\.stringValue),
                !methods.contains("S256")
            {
                throw OAuthError("This server's sign-in does not support the PKCE protection this app requires.")
            }
            return OAuthServerInfo(
                resource: resource, authorizationEndpoint: authorize, tokenEndpoint: token,
                registrationEndpoint: metadata["registration_endpoint"]?.stringValue.flatMap { URL(string: $0) },
                scopes: scopes ?? [])
        }

        // No metadata anywhere: the paths older MCP servers are required to use.
        guard let authorize = URL(string: "/authorize", relativeTo: authorizationServer)?.absoluteURL,
            let token = URL(string: "/token", relativeTo: authorizationServer)?.absoluteURL
        else { throw OAuthError("Could not find how to sign in to this server.") }
        return OAuthServerInfo(
            resource: resource, authorizationEndpoint: authorize, tokenEndpoint: token,
            registrationEndpoint: URL(string: "/register", relativeTo: authorizationServer)?.absoluteURL,
            scopes: scopes ?? [])
    }

    // MARK: Registration

    /// Registers this app with the authorization server.
    public func register(_ info: OAuthServerInfo, redirectURI: String) async throws -> OAuthClientRegistration {
        guard let endpoint = info.registrationEndpoint else {
            throw OAuthError("This service does not let apps register themselves. Add a client ID from its developer settings.")
        }
        let body: JSONValue = [
            "client_name": .string(clientName),
            "redirect_uris": [.string(redirectURI)],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "application_type": "native",
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = Data(body.jsonString.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let value = try await Self.object(from: session, request, doing: "register this app")
        guard let clientID = value["client_id"]?.stringValue else {
            throw OAuthError("The service did not give this app a client ID.")
        }
        return OAuthClientRegistration(clientID: clientID, clientSecret: value["client_secret"]?.stringValue)
    }

    // MARK: Authorization code with PKCE

    public struct AuthorizationRequest: Sendable {
        public var url: URL
        public var verifier: String
        public var state: String
    }

    static func randomToken(bytes: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return base64URL(data)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The PKCE challenge for a verifier.
    public static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// The page to open in a browser for the user to approve access.
    public func authorizationRequest(
        _ info: OAuthServerInfo, client: OAuthClientRegistration, redirectURI: String
    ) throws -> AuthorizationRequest {
        guard var components = URLComponents(url: info.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw OAuthError("The sign-in address is not valid.")
        }
        let verifier = Self.randomToken(bytes: 48)
        let state = Self.randomToken(bytes: 16)
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        // Only MCP servers are named as the token's resource; other services reject the field.
        if !info.resource.isEmpty { items.append(URLQueryItem(name: "resource", value: info.resource)) }
        if !info.scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: info.scopes.joined(separator: " "))) }
        components.queryItems = items
        // URLComponents leaves "+" alone, which servers read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw OAuthError("The sign-in address is not valid.") }
        return AuthorizationRequest(url: url, verifier: verifier, state: state)
    }

    /// The authorization code in the address the browser was sent back to.
    public static func code(fromCallback url: URL, state: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            if error == "access_denied" { throw OAuthError("Access was not approved.") }
            throw OAuthError("Sign-in failed: \(value("error_description") ?? error)")
        }
        guard value("state") == state else { throw OAuthError("Sign-in failed: the reply did not match the request.") }
        guard let code = value("code"), !code.isEmpty else { throw OAuthError("Sign-in failed: no code came back.") }
        return code
    }

    public func exchange(
        code: String, verifier: String, info: OAuthServerInfo, client: OAuthClientRegistration, redirectURI: String
    ) async throws -> OAuthTokens {
        try await token(
            info, client: client,
            fields: [
                "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
                "code_verifier": verifier,
            ], previous: nil)
    }

    /// Trades the refresh token for a new access token.
    public func refresh(_ credentials: MCPCredentials) async throws -> OAuthTokens {
        guard let refreshToken = credentials.tokens.refreshToken else { throw OAuthError("There is no refresh token.") }
        return try await token(
            credentials.server, client: credentials.client,
            fields: ["grant_type": "refresh_token", "refresh_token": refreshToken], previous: refreshToken)
    }

    private func token(
        _ info: OAuthServerInfo, client: OAuthClientRegistration, fields: [String: String], previous: String?
    ) async throws -> OAuthTokens {
        var fields = fields
        fields["client_id"] = client.clientID
        if !info.resource.isEmpty { fields["resource"] = info.resource }
        if let secret = client.clientSecret { fields["client_secret"] = secret }
        var request = URLRequest(url: info.tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = Data(Self.formEncoded(fields).utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let value = try await Self.object(from: session, request, doing: "finish signing in")
        guard let accessToken = value["access_token"]?.stringValue else {
            throw OAuthError("The service did not return an access token.")
        }
        return OAuthTokens(
            accessToken: accessToken,
            // A server that does not rotate refresh tokens leaves the old one in force.
            refreshToken: value["refresh_token"]?.stringValue ?? previous,
            expiresAt: value["expires_in"]?.doubleValue.map { Date().addingTimeInterval($0) })
    }

    static func formEncoded(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }

    private static func object(from session: URLSession, _ request: URLRequest, doing task: String) async throws -> JSONValue {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OAuthError("Could not \(task): \(error.localizedDescription)")
        }
        let value = JSONValue(jsonString: String(decoding: data, as: UTF8.self))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let value else {
            let reason = value?["error_description"]?.stringValue ?? value?["error"]?.stringValue ?? "status \(status)"
            throw OAuthError("Could not \(task): \(reason)")
        }
        return value
    }

    // MARK: The whole flow

    /// Signs in to the MCP server at `serverURL`.
    ///
    /// `clientID` is for services where the app was registered by hand; without
    /// one the app registers itself. `present` opens the approval page and
    /// returns the address the browser was sent back to.
    public func signIn(
        serverURL: URL, challenge: String?, clientID: String? = nil, clientSecret: String? = nil,
        scopes: [String]? = nil, redirectURI: String,
        present: @Sendable (URL) async throws -> URL
    ) async throws -> MCPCredentials {
        var info = try await discover(serverURL: serverURL, challenge: challenge)
        // Asking for less than everything the server offers, when the caller knows what it needs.
        if let scopes, !scopes.isEmpty { info.scopes = scopes }
        let client: OAuthClientRegistration
        if let clientID, !clientID.isEmpty {
            client = OAuthClientRegistration(clientID: clientID, clientSecret: clientSecret.flatMap { $0.isEmpty ? nil : $0 })
        } else {
            client = try await register(info, redirectURI: redirectURI)
        }
        let request = try authorizationRequest(info, client: client, redirectURI: redirectURI)
        let callback = try await present(request.url)
        let code = try Self.code(fromCallback: callback, state: request.state)
        let tokens = try await exchange(
            code: code, verifier: request.verifier, info: info, client: client, redirectURI: redirectURI)
        return MCPCredentials(server: info, client: client, tokens: tokens)
    }
}
