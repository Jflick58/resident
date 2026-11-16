import AuthenticationServices
import Foundation
import HarnessKit
import Observation
import UIKit

/// The connectors the user has added: MCP servers, their sign-ins and their tools.
///
/// What a server offers is saved with it, so a chat can use its tools without
/// asking the server again first. Sign-ins live in the Keychain.
@MainActor
@Observable
final class ConnectorsModel {
    /// Where the service sends the browser back to after the user approves.
    static let redirectURI = AppIdentity.bundleID + "://oauth"

    private let store: Store
    private(set) var servers: [MCPServerConfig]
    @ObservationIgnored private var connections: [UUID: MCPConnection] = [:]
    @ObservationIgnored private let browser = SignInBrowser()

    init(store: Store) {
        self.store = store
        servers = store.loadServers()
    }

    func server(_ id: UUID) -> MCPServerConfig? { servers.first { $0.id == id } }

    private func update(_ id: UUID, _ change: (inout MCPServerConfig) -> Void) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        change(&servers[index])
        store.save(servers)
    }

    private func connection(for server: MCPServerConfig) -> MCPConnection? {
        if let existing = connections[server.id] { return existing }
        guard let url = URL(string: server.url) else { return nil }
        let id = server.id
        let saved = Keychain.get("mcp.\(id.uuidString)").flatMap {
            try? JSONDecoder().decode(MCPCredentials.self, from: Data($0.utf8))
        }
        let connection = MCPConnection(url: url, credentials: saved) { credentials in
            let text = credentials.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
            Keychain.set(text ?? "", for: "mcp.\(id.uuidString)")
        }
        connections[id] = connection
        return connection
    }

    // MARK: Tools for a chat

    /// The switched-on tools of these servers, ready for the agent.
    func tools(for ids: [UUID]) -> [any Tool] {
        ids.compactMap { server($0) }.flatMap { server -> [any Tool] in
            guard let connection = connection(for: server) else { return [] }
            return server.enabledTools.map { MCPTool(connection: connection, server: server, info: $0) }
        }
    }

    /// The same tools as one group per server, for when they are held back until needed.
    func groups(for ids: [UUID]) -> [ToolGroup] {
        ids.compactMap { server($0) }.compactMap { server -> ToolGroup? in
            guard let connection = connection(for: server), !server.needsSignIn else { return nil }
            return ToolGroup(
                name: server.toolPrefix, title: server.name, summary: server.summary ?? "",
                tools: server.enabledTools.map { MCPTool(connection: connection, server: server, info: $0) },
                guidance: server.instructions ?? "")
        }
    }

    func toolCount(for ids: [UUID]) -> Int {
        ids.compactMap { server($0) }.reduce(0) { $0 + $1.enabledTools.count }
    }

    /// A plain line for the transcript when a call belongs to one of these servers.
    func activity(forTool name: String) -> String? {
        for server in servers {
            if let tool = server.tools.first(where: { server.exposedName(for: $0.name) == name }) {
                return "\(server.name): \(MCPTool.readableName(tool))"
            }
        }
        return nil
    }

    // MARK: Adding and signing in

    /// Adds a server: connects, signs in if it asks for that, and reads its tools.
    @discardableResult
    func add(
        address: String, name: String = "", clientID: String = "", clientSecret: String = "",
        scopes: [String]? = nil, onlyTools: [String]? = nil, signInFirst: Bool = false, summary: String? = nil
    ) async throws -> MCPServerConfig {
        guard let url = MCPServerConfig.normalizedURL(address) else {
            throw OAuthError("That does not look like a web address.")
        }
        if let existing = servers.first(where: { $0.url == url.absoluteString }) {
            throw OAuthError("\(existing.name) is already added.")
        }
        var server = MCPServerConfig(
            name: name.trimmingCharacters(in: .whitespaces), url: url.absoluteString, summary: summary,
            clientID: clientID.trimmingCharacters(in: .whitespaces).isEmpty ? nil : clientID.trimmingCharacters(in: .whitespaces),
            scopes: scopes)
        Keychain.set(clientSecret.trimmingCharacters(in: .whitespaces), for: "mcp.secret.\(server.id.uuidString)")
        guard let connection = connection(for: server) else { throw OAuthError("That does not look like a web address.") }
        do {
            do {
                // Some servers list their tools to anyone and only refuse calls, so
                // a service known to need an account is signed in to up front.
                if signInFirst { throw MCPError.needsSignIn(challenge: nil) }
                server.tools = try await connection.listTools()
            } catch MCPError.needsSignIn(let challenge) {
                try await signIn(server, connection: connection, challenge: challenge)
                server.isSignedIn = true
                server.tools = try await connection.listTools()
            }
        } catch {
            connections[server.id] = nil
            Keychain.set("", for: "mcp.\(server.id.uuidString)")
            Keychain.set("", for: "mcp.secret.\(server.id.uuidString)")
            throw error
        }
        server.instructions = await connection.instructions
        // A service with many tools starts with the useful few switched on.
        if let onlyTools { server.disabledTools = server.tools.map(\.name).filter { !onlyTools.contains($0) } }
        if server.name.isEmpty {
            server.name = await connection.serverName ?? Self.name(fromHost: url)
        }
        // Two servers must not share a tool prefix, or their tools would collide.
        let base = server.name
        var suffix = 2
        while servers.contains(where: { $0.toolPrefix == server.toolPrefix }) {
            server.name = "\(base) \(suffix)"
            suffix += 1
        }
        servers.append(server)
        store.save(servers)
        return server
    }

    private static func name(fromHost url: URL) -> String {
        let parts = (url.host ?? "Server").split(separator: ".").filter { !["mcp", "www", "api"].contains($0) }
        return (parts.first.map(String.init) ?? "Server").capitalized
    }

    private func signIn(_ server: MCPServerConfig, connection: MCPConnection, challenge: String?) async throws {
        guard let url = URL(string: server.url) else { return }
        let browser = browser
        let redirect = MCPServerConfig.redirectURI(clientID: server.clientID, default: Self.redirectURI)
        let scheme = String(redirect.prefix { $0 != ":" })
        let credentials = try await OAuthFlow().signIn(
            serverURL: url, challenge: challenge, clientID: server.clientID,
            clientSecret: Keychain.get("mcp.secret.\(server.id.uuidString)"), scopes: server.scopes, redirectURI: redirect
        ) { page in
            try await browser.open(page, callbackScheme: scheme)
        }
        await connection.setCredentials(credentials)
    }

    /// Signs in to a server that is already added, then reads its tools again.
    func signIn(_ id: UUID) async throws {
        guard let server = server(id), let connection = connection(for: server) else { return }
        try await signIn(server, connection: connection, challenge: nil)
        update(id) {
            $0.isSignedIn = true
            $0.needsSignIn = false
        }
        try await refreshTools(id)
    }

    /// Asks the server what it offers now.
    func refreshTools(_ id: UUID) async throws {
        guard let server = server(id), let connection = connection(for: server) else { return }
        do {
            let tools = try await connection.listTools()
            let instructions = await connection.instructions
            update(id) {
                $0.tools = tools
                $0.instructions = instructions ?? $0.instructions
                $0.needsSignIn = false
            }
        } catch MCPError.needsSignIn {
            update(id) { $0.needsSignIn = true }
            throw MCPError.needsSignIn(challenge: nil)
        }
    }

    func signOut(_ id: UUID) {
        guard let server = server(id) else { return }
        let connection = connection(for: server)
        Task { await connection?.setCredentials(nil) }
        update(id) {
            $0.isSignedIn = false
            $0.needsSignIn = true
        }
    }

    func remove(_ id: UUID) {
        Keychain.set("", for: "mcp.\(id.uuidString)")
        Keychain.set("", for: "mcp.secret.\(id.uuidString)")
        connections[id] = nil
        servers.removeAll { $0.id == id }
        store.save(servers)
    }

    func setTool(_ name: String, enabled: Bool, in id: UUID) {
        update(id) {
            $0.disabledTools.removeAll { $0 == name }
            if !enabled { $0.disabledTools.append(name) }
        }
    }

    func setAllTools(enabled: Bool, in id: UUID) {
        update(id) { $0.disabledTools = enabled ? [] : $0.tools.map(\.name) }
    }
}

/// Shows a service's approval page in the system's sign-in browser, which shares
/// Safari's logins and never lets the app see the password.
@MainActor
final class SignInBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var current: ASWebAuthenticationSession?

    func open(_ url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    continuation.resume(throwing: OAuthError("Sign-in was cancelled."))
                } else {
                    continuation.resume(throwing: OAuthError(error?.localizedDescription ?? "Sign-in failed."))
                }
            }
            session.presentationContextProvider = self
            #if DEBUG
                // `-ephemeralSignIn YES` skips the system's consent prompt, for driving sign-in from the command line.
                session.prefersEphemeralWebBrowserSession = UserDefaults.standard.bool(forKey: "ephemeralSignIn")
            #endif
            current = session
            if !session.start() {
                current = nil
                continuation.resume(throwing: OAuthError("The sign-in page could not be opened."))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first.map { UIWindow(windowScene: $0) } ?? UIWindow()
        }
    }
}
