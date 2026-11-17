import Foundation
import Testing

@testable import HarnessKit

// MARK: A stand-in MCP server with OAuth, answered from inside the process

/// Answers the requests a real MCP server and its authorization server would:
/// metadata, registration, approval, tokens, and the MCP endpoint itself.
private final class StubServer: @unchecked Sendable {
    var requiresSignIn = true
    /// Answer `tools/call` as an event stream instead of plain JSON.
    var streamsResults = false
    /// When set, the session with this id is forgotten once.
    var forgetSession = false

    private(set) var registrations = 0
    private(set) var refreshes = 0
    private(set) var initializations = 0
    private(set) var seenResources: [String] = []
    private var challenges: [String: String] = [:]
    private var validTokens: Set<String> = []
    private var refreshTokens: Set<String> = []
    private var counter = 0
    private var devicePolls = 0
    var codeEntered = true
    private let lock = NSLock()

    func expireAccessTokens() {
        lock.withLock { validTokens = [] }
    }

    func revokeEverything() {
        lock.withLock {
            validTokens = []
            refreshTokens = []
        }
    }

    private func json(_ value: JSONValue, status: Int = 200, headers: [String: String] = [:]) -> (Int, [String: String], Data) {
        (status, headers.merging(["Content-Type": "application/json"]) { a, _ in a }, Data(value.jsonString.utf8))
    }

    private func issue() -> JSONValue {
        counter += 1
        let access = "access-\(counter)"
        let refresh = "refresh-\(counter)"
        validTokens.insert(access)
        refreshTokens.insert(refresh)
        return ["access_token": .string(access), "refresh_token": .string(refresh), "expires_in": 3600, "token_type": "Bearer"]
    }

    func handle(_ request: URLRequest, body: Data) -> (Int, [String: String], Data) {
        lock.lock()
        defer { lock.unlock() }
        let url = request.url!
        let form = Dictionary(
            String(decoding: body, as: UTF8.self).split(separator: "&").compactMap { pair -> (String, String)? in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                return parts.count == 2 ? (parts[0], parts[1].removingPercentEncoding ?? parts[1]) : nil
            }, uniquingKeysWith: { a, _ in a })

        switch (url.host, url.path) {
        case ("mcp.test", "/.well-known/oauth-protected-resource/mcp"):
            return json([
                "resource": "https://mcp.test/mcp", "authorization_servers": ["https://auth.test/tenant"],
                "scopes_supported": ["read", "write"],
            ])
        case ("auth.test", "/.well-known/oauth-authorization-server/tenant"):
            return json([
                "issuer": "https://auth.test/tenant", "authorization_endpoint": "https://auth.test/authorize",
                "token_endpoint": "https://auth.test/token", "registration_endpoint": "https://auth.test/register",
                "code_challenge_methods_supported": ["S256"], "device_authorization_endpoint": "https://auth.test/device",
            ])
        case ("auth.test", "/device"):
            return json(["device_code": "device-1", "user_code": "ABCD-1234", "verification_uri": "https://auth.test/enter", "interval": 1])
        case ("auth.test", "/register"):
            registrations += 1
            return json(["client_id": .string("client-\(registrations)")], status: 201)
        case ("auth.test", "/authorize"):
            // Approves at once and says where the browser would be sent.
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
            counter += 1
            let code = "code-\(counter)"
            challenges[code] = value("code_challenge")
            seenResources.append(value("resource"))
            return json(["location": .string("\(value("redirect_uri"))?code=\(code)&state=\(value("state"))")])
        case ("auth.test", "/token"):
            seenResources.append(form["resource"] ?? "")
            if form["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code" {
                // "Not yet" the way GitHub says it, with status 200, until the code has been entered.
                devicePolls += 1
                guard form["device_code"] == "device-1", devicePolls > 1, codeEntered else { return json(["error": "authorization_pending"]) }
                return json(issue())
            }
            if form["grant_type"] == "authorization_code" {
                guard let code = form["code"], let challenge = challenges.removeValue(forKey: code),
                    OAuthFlow.codeChallenge(for: form["code_verifier"] ?? "") == challenge
                else { return json(["error": "invalid_grant", "error_description": "bad code or verifier"], status: 400) }
                return json(issue())
            }
            guard let refresh = form["refresh_token"], refreshTokens.remove(refresh) != nil else {
                return json(["error": "invalid_grant"], status: 400)
            }
            refreshes += 1
            return json(issue())
        case ("mcp.test", "/mcp"):
            return mcp(request, body: body)
        default:
            return (404, [:], Data())
        }
    }

    private func mcp(_ request: URLRequest, body: Data) -> (Int, [String: String], Data) {
        if requiresSignIn {
            let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
            guard validTokens.contains(token) else {
                return (401, ["WWW-Authenticate": "Bearer resource_metadata=\"https://mcp.test/.well-known/oauth-protected-resource/mcp\""], Data())
            }
        }
        guard let message = JSONValue(jsonString: String(decoding: body, as: UTF8.self)) else { return (400, [:], Data()) }
        let method = message["method"]?.stringValue ?? ""
        let id = message["id"] ?? .null
        func result(_ value: JSONValue, headers: [String: String] = [:]) -> (Int, [String: String], Data) {
            json(["jsonrpc": "2.0", "id": id, "result": value], headers: headers)
        }
        if method != "initialize", request.value(forHTTPHeaderField: "Mcp-Session-Id") != "session-\(initializations)" {
            return (404, [:], Data())
        }
        switch method {
        case "initialize":
            initializations += 1
            return result(
                ["protocolVersion": "2025-06-18", "serverInfo": ["name": "stub", "title": "Stub Notes"], "capabilities": ["tools": [:]]],
                headers: ["Mcp-Session-Id": "session-\(initializations)"])
        case "notifications/initialized":
            return (202, [:], Data())
        case "tools/list":
            if forgetSession {
                forgetSession = false
                initializations += 100
                return (404, [:], Data())
            }
            if message["params"]?["cursor"] == nil {
                return result([
                    "tools": [["name": "search", "description": "Search notes", "inputSchema": ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]]],
                    "nextCursor": "page2",
                ])
            }
            return result(["tools": [["name": "create-note", "title": "Create Note", "description": "Create a note", "inputSchema": ["type": "object"]]]])
        case "tools/call":
            let query = message["params"]?["arguments"]?["query"]?.stringValue ?? ""
            let answer: JSONValue = ["content": [["type": "text", "text": .string("Found: \(query)")]], "isError": .bool(query == "fail")]
            guard streamsResults else { return result(answer) }
            let response: JSONValue = ["jsonrpc": "2.0", "id": id, "result": answer]
            let stream =
                ": keep-alive\n\nevent: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\n\n"
                + "event: message\r\ndata: \(response.jsonString)\r\n\r\n"
            return (200, ["Content-Type": "text/event-stream"], Data(stream.utf8))
        default:
            return json(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
        }
    }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var server = StubServer()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession hands a protocol the body as a stream.
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let (status, headers, data) = Self.server.handle(request, body: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session(_ server: StubServer) -> URLSession {
        Self.server = server
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private let serverURL = URL(string: "https://mcp.test/mcp")!
private let redirect = "com.jflick.resident:/oauth"

/// Stands in for the browser: asks the stub to approve and returns where it would redirect.
private func approve(_ session: URLSession) -> @Sendable (URL) async throws -> URL {
    { url in
        let (data, _) = try await session.data(from: url)
        let location = JSONValue(jsonString: String(decoding: data, as: UTF8.self))?["location"]?.stringValue ?? ""
        return URL(string: location)!
    }
}

// MARK: Tests

@Suite struct MCPParsingTests {
    @Test func splitsEventStreams() {
        var parser = SSEParser()
        #expect(parser.feed(": comment") == nil)
        #expect(parser.feed("event: message") == nil)
        #expect(parser.feed("data: {\"a\":1}") == nil)
        #expect(parser.feed("") == "{\"a\":1}")
        #expect(parser.feed("") == nil)
        #expect(parser.feed("data:first") == nil)
        #expect(parser.feed("data: second") == nil)
        #expect(parser.finish() == "first\nsecond")
    }

    @Test func readsTheSignInChallenge() {
        let header = "Bearer error=\"invalid_token\", resource_metadata=\"https://mcp.test/.well-known/oauth-protected-resource\", scope=\"read write\""
        let challenge = OAuthFlow.challenge(header)
        #expect(challenge.resourceMetadata?.absoluteString == "https://mcp.test/.well-known/oauth-protected-resource")
        #expect(challenge.scope == "read write")
        #expect(OAuthFlow.challenge("Bearer").resourceMetadata == nil)
        #expect(OAuthFlow.challenge(nil).scope == nil)
    }

    @Test func buildsWellKnownAddresses() {
        let withPath = OAuthFlow.wellKnown("oauth-protected-resource", for: URL(string: "https://example.com/v1/mcp/?x=1")!)
        #expect(withPath.map(\.absoluteString) == [
            "https://example.com/.well-known/oauth-protected-resource/v1/mcp",
            "https://example.com/.well-known/oauth-protected-resource",
        ])
        let issuer = OAuthFlow.wellKnown("openid-configuration", for: URL(string: "https://example.com/tenant")!, openIDSuffix: true)
        #expect(issuer.map(\.absoluteString) == [
            "https://example.com/.well-known/openid-configuration/tenant",
            "https://example.com/tenant/.well-known/openid-configuration",
            "https://example.com/.well-known/openid-configuration",
        ])
        #expect(OAuthFlow.wellKnown("oauth-authorization-server", for: URL(string: "https://example.com")!).count == 1)
    }

    @Test func makesThePKCEChallengeFromTheStandard() {
        // The worked example in RFC 7636, appendix B.
        #expect(OAuthFlow.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func readsTheCallback() throws {
        #expect(try OAuthFlow.code(fromCallback: URL(string: "app:/oauth?code=abc&state=s1")!, state: "s1") == "abc")
        #expect(throws: OAuthError.self) { try OAuthFlow.code(fromCallback: URL(string: "app:/oauth?code=abc&state=other")!, state: "s1") }
        #expect(throws: OAuthError("Access was not approved.")) {
            try OAuthFlow.code(fromCallback: URL(string: "app:/oauth?error=access_denied&state=s1")!, state: "s1")
        }
    }

    @Test func namesToolsAfterTheirServer() {
        let server = MCPServerConfig(name: "Linear (Work)", url: "https://mcp.linear.app/mcp")
        #expect(server.toolPrefix == "linear_work")
        #expect(server.exposedName(for: "list_issues") == "linear_work_list_issues")
        #expect(server.exposedName(for: "linear_work_search") == "linear_work_search")
        #expect(server.exposedName(for: "get issue/by id") == "linear_work_get_issue_by_id")
        #expect(MCPServerConfig.normalizedURL("mcp.linear.app/mcp")?.absoluteString == "https://mcp.linear.app/mcp")
        #expect(MCPServerConfig.normalizedURL("ftp://example.com") == nil)
        #expect(MCPServerConfig.normalizedURL("not a url") == nil)
    }
}

@Suite(.serialized) struct MCPServerTests {
    @Test func signsInWithACodeAndNoSecret() async throws {
        let server = StubServer()
        let session = StubProtocol.session(server)
        let credentials = try await OAuthFlow(session: session).signInWithCode(serverURL: serverURL, challenge: nil, clientID: "public-id") {
            code, page in
            #expect(code == "ABCD-1234" && page.absoluteString == "https://auth.test/enter")
            // The page stays open until the approval arrives and closes it.
            try await Task.sleep(for: .seconds(60))
        }
        #expect(credentials.client.clientSecret == nil)
        let connection = MCPConnection(url: serverURL, credentials: credentials, session: session)
        #expect(try await connection.listTools().count == 2)
    }

    @Test func givesUpWhenThePageIsClosedWithoutTheCode() async throws {
        let server = StubServer()
        server.codeEntered = false
        let flow = OAuthFlow(session: StubProtocol.session(server))
        await #expect(throws: OAuthError("Access was not approved.")) {
            _ = try await flow.signInWithCode(serverURL: serverURL, challenge: nil, clientID: "public-id") { _, _ in }
        }
    }

    @Test func listsAndCallsToolsWithoutSignIn() async throws {
        let server = StubServer()
        server.requiresSignIn = false
        let connection = MCPConnection(url: serverURL, credentials: nil, session: StubProtocol.session(server))

        let tools = try await connection.listTools()
        #expect(tools.map(\.name) == ["search", "create-note"])
        #expect(tools[1].title == "Create Note")
        #expect(await connection.serverName == "Stub Notes")

        let result = try await connection.callTool("search", arguments: ["query": "milk"])
        #expect(result.text == "Found: milk")
        #expect(!result.isError)
        #expect(try await connection.callTool("search", arguments: ["query": "fail"]).isError)
        #expect(server.initializations == 1)
    }

    @Test func readsAnswersSentAsAnEventStream() async throws {
        let server = StubServer()
        server.requiresSignIn = false
        server.streamsResults = true
        let connection = MCPConnection(url: serverURL, credentials: nil, session: StubProtocol.session(server))
        #expect(try await connection.callTool("search", arguments: ["query": "eggs"]).text == "Found: eggs")
    }

    @Test func startsAForgottenSessionAgain() async throws {
        let server = StubServer()
        server.requiresSignIn = false
        let connection = MCPConnection(url: serverURL, credentials: nil, session: StubProtocol.session(server))
        _ = try await connection.listTools()
        server.forgetSession = true
        #expect(try await connection.listTools().count == 2)
    }

    @Test func signsInThenRenewsTheToken() async throws {
        let server = StubServer()
        let session = StubProtocol.session(server)
        let saved = Saved()
        let connection = MCPConnection(url: serverURL, credentials: nil, session: session) { saved.set($0) }

        // Without a sign-in the server refuses, and says where to look.
        var challenge: String?
        do {
            _ = try await connection.listTools()
            Issue.record("Expected a sign-in to be needed")
        } catch MCPError.needsSignIn(let header) {
            challenge = header
        }
        #expect(challenge?.contains("resource_metadata") == true)

        let credentials = try await OAuthFlow(session: session).signIn(
            serverURL: serverURL, challenge: challenge, redirectURI: redirect, present: approve(session))
        #expect(credentials.client.clientID == "client-1")
        #expect(credentials.server.scopes == ["read", "write"])
        #expect(credentials.server.tokenEndpoint.absoluteString == "https://auth.test/token")
        // The token is asked for the MCP server by name, at both steps.
        #expect(server.seenResources == ["https://mcp.test/mcp", "https://mcp.test/mcp"])

        await connection.setCredentials(credentials)
        #expect(try await connection.listTools().count == 2)

        // The access token stops working: it is renewed without the user.
        server.expireAccessTokens()
        #expect(try await connection.callTool("search", arguments: ["query": "tea"]).text == "Found: tea")
        #expect(server.refreshes == 1)
        #expect(saved.value?.tokens.accessToken != credentials.tokens.accessToken)

        // Nothing left to renew with: the user has to sign in again.
        server.revokeEverything()
        await #expect(throws: MCPError.self) { try await connection.listTools() }
        let tool = MCPTool(connection: connection, server: MCPServerConfig(name: "Notes", url: serverURL.absoluteString), info: MCPToolInfo(name: "search", description: "", inputSchema: [:]))
        let failed = await tool.call(["query": "tea"])
        #expect(failed.isError)
        #expect(failed.text.contains("sign in"))
    }

    @Test func usesAClientIDGivenByHand() async throws {
        let server = StubServer()
        let session = StubProtocol.session(server)
        let credentials = try await OAuthFlow(session: session).signIn(
            serverURL: serverURL, challenge: nil, clientID: "by-hand", redirectURI: redirect, present: approve(session))
        #expect(credentials.client.clientID == "by-hand")
        #expect(server.registrations == 0)
    }

    @Test func toolResultsAreCutToFit() async throws {
        let server = StubServer()
        server.requiresSignIn = false
        let connection = MCPConnection(url: serverURL, credentials: nil, session: StubProtocol.session(server))
        let config = MCPServerConfig(name: "Notes", url: serverURL.absoluteString)
        let tool = MCPTool(connection: connection, server: config, info: MCPToolInfo(name: "search", description: "Search notes", inputSchema: [:]))
        #expect(tool.spec.name == "notes_search")
        #expect(tool.spec.description == "[Notes] Search notes")
        // Plain text of a file's length is passed on whole, for the agent to show a part at a time.
        let file = await tool.call(["query": .string(String(repeating: "x", count: 9000))])
        #expect(file.text.count > 9000)
        #expect(!file.text.contains("Result cut"))
        let huge = await tool.call(["query": .string(String(repeating: "x", count: 70000))])
        #expect(huge.text.count < 60200)
        #expect(huge.text.contains("Result cut"))
    }
}

private final class Saved: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: MCPCredentials?
    var value: MCPCredentials? { lock.withLock { stored } }
    func set(_ credentials: MCPCredentials?) { lock.withLock { stored = credentials } }
}

@Suite struct SkillTests {
    @Test func readsASkillFile() {
        let skill = Skill.parse(markdown: "---\nname: Weekly Review\ndescription: \"Reviewing the week\"\n---\n\n# Steps\n1. Look back.\n", fallbackName: "x")
        #expect(skill.name == "weekly-review")
        #expect(skill.summary == "Reviewing the week")
        #expect(skill.instructions == "# Steps\n1. Look back.")
        let bare = Skill.parse(markdown: "# Packing list\nAlways pack socks.", fallbackName: "Trip Packing")
        #expect(bare.name == "trip-packing")
        #expect(bare.summary == "Packing list")
    }

    @Test func listsOnlyEnabledSkillsAndLoadsThemByName() async {
        var off = Skill(name: "hidden", summary: "Never", instructions: "No.")
        off.isEnabled = false
        let skills = [Skill(name: "write-email", summary: "Drafting an email", instructions: "Subject first."), off]
        let section = Skill.promptSection(skills)
        #expect(section?.contains("- write-email: Drafting an email") == true)
        #expect(section?.contains("hidden") == false)
        #expect(Skill.promptSection([off]) == nil)

        let tool = UseSkillTool(skills: skills)
        #expect(await tool.call(["name": "Write Email"]).text.contains("Subject first."))
        #expect(await tool.call(["name": "email"]).text.contains("Subject first."))
        let missing = await tool.call(["name": "hidden"])
        #expect(missing.isError)
        #expect(missing.text.contains("write-email"))
    }

    @Test func promptListsSkillsOnlyWhenThePresetUsesThem() {
        let skills = [Skill(name: "plan-day", summary: "Planning a day", instructions: "Look first.")]
        #expect(PromptBuilder.systemPrompt(preset: .assistant, memory: "", skills: skills).contains("- plan-day: Planning a day"))
        #expect(!PromptBuilder.systemPrompt(preset: .chat, memory: "", skills: skills).contains("plan-day"))
    }

    @Test func googleClientsGetTheirOwnCallbackAddress() {
        #expect(MCPServerConfig.redirectURI(clientID: "123-abc.apps.googleusercontent.com", default: "app:/oauth") == "com.googleusercontent.apps.123-abc:/oauth2redirect")
        #expect(MCPServerConfig.redirectURI(clientID: "Iv1.abc", default: "app:/oauth") == "app:/oauth")
        #expect(MCPServerConfig.redirectURI(clientID: nil, default: "app:/oauth") == "app:/oauth")
    }
}

@Suite struct AttachmentTests {
    private let long = DocumentAttachment(
        name: "report.pdf", parts: (1...5).map { "Page \($0) text. " + String(repeating: "filler ", count: 300) + ($0 == 4 ? "The invoice total is 4,210 euros." : "") },
        partNoun: "page")

    @Test func splitsTextIntoParts() {
        let document = DocumentAttachment(name: "notes.txt", text: (1...200).map { "Line \($0) of the notes." }.joined(separator: "\n"), partSize: 1000)
        #expect(document.parts.count > 3)
        #expect(document.parts.allSatisfy { $0.count <= 1000 })
        #expect(document.parts.joined(separator: "\n").contains("Line 200 of the notes."))
    }

    @Test func shortDocumentsGoInWhole() {
        let message = Message.user("What is this?", documents: [DocumentAttachment(name: "a.txt", text: "Hello there.")])
        let rendered = AttachmentRenderer.render(message, vision: false)
        #expect(rendered.text.contains("shown in full"))
        #expect(rendered.text.contains("Hello there."))
        #expect(rendered.text.hasSuffix("What is this?"))
        #expect(rendered.documents == nil)
    }

    @Test func longDocumentsShowTheirOpeningAndPointToTheTool() {
        let rendered = AttachmentRenderer.render(.user("Total?", documents: [long]), vision: false)
        #expect(rendered.text.contains("5 pages"))
        #expect(rendered.text.contains("read_document"))
        #expect(rendered.text.contains("Page 1 text."))
        #expect(!rendered.text.contains("Page 4 text."))
        #expect(rendered.text.count < 4500)
    }

    @Test func photosBecomeTheirTextForModelsThatCannotSee() {
        let photo = ImageAttachment(data: Data([1]), recognizedText: "EXIT 12 Springfield")
        let blind = AttachmentRenderer.render(.user("Where is this?", images: [photo]), vision: false)
        #expect(blind.images.isEmpty)
        #expect(blind.text.contains("EXIT 12 Springfield"))
        let sighted = AttachmentRenderer.render(.user("Where is this?", images: [photo]), vision: true)
        #expect(sighted.images.count == 1)
        #expect(sighted.text == "Where is this?")
        let nothing = AttachmentRenderer.render(.user("", images: [ImageAttachment(data: Data([1]))]), vision: false)
        #expect(nothing.text.contains("cannot see"))
    }

    @Test func readsAndSearchesTheRest() async {
        let tool = ReadDocumentTool(documents: [long])
        #expect(await tool.call(["part": 4]).text.contains("4,210 euros"))
        let found = await tool.call(["search": "invoice total"])
        #expect(found.text.contains("[Page 4 of 5]"))
        #expect(found.text.contains("4,210 euros"))
        #expect(await tool.call(["part": 9]).isError)
        #expect(await tool.call(["search": "zebra"]).text.contains("Nothing in"))
        #expect(await tool.call([:]).isError)
    }

    @Test func oldChatsWithoutDocumentsStillDecode() throws {
        let old = #"{"id":"A0000000-0000-4000-8000-000000000009","role":"user","text":"hi","reasoning":"","toolCalls":[],"isError":false,"images":[{"id":"A0000000-0000-4000-8000-00000000000A","data":"AQ==","mimeType":"image/jpeg"}],"date":0}"#
        let message = try JSONDecoder().decode(Message.self, from: Data(old.utf8))
        #expect(message.documents == nil)
        #expect(message.images.first?.recognizedText == nil)
    }
}

@Suite struct MemoryControlTests {
    private func store() -> MemoryStore {
        MemoryStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("memory-\(UUID().uuidString).md"))
    }

    @Test func forgetsByPhraseOrByMeaning() {
        let memory = store()
        memory.setFacts(["Lives in Lisbon", "Prefers metric units", "Is allergic to peanuts"])
        #expect(memory.forget("lisbon") == ["Lives in Lisbon"])
        #expect(memory.forget("the peanut allergy thing") == [])
        #expect(memory.forget("allergic peanuts") == ["Is allergic to peanuts"])
        #expect(memory.facts == ["Prefers metric units"])
    }

    @Test func theToolCorrectsAndRemoves() async {
        let memory = store()
        memory.setFacts(["Lives in Lisbon"])
        let tool = SaveMemoryTool(store: memory)
        let corrected = await tool.call(["fact": "Lives in Porto", "forget": "Lives in Lisbon"])
        #expect(corrected.text.contains("Forgot") && corrected.text.contains("Saved"))
        #expect(memory.facts == ["Lives in Porto"])
        #expect(!(await tool.call(["forget": "Porto"])).isError)
        #expect(memory.facts.isEmpty)
        #expect(await tool.call(["forget": "unicorns"]).isError)
        #expect(await tool.call([:]).isError)
    }
}
