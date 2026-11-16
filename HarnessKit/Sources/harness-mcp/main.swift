import Foundation
import HarnessKit

// Checks an MCP server from the command line:
//   swift run harness-mcp <url> [--register] [--call tool '{"json":"args"}']
// Lists its tools when no sign-in is needed. Otherwise shows where sign-in
// would happen and, with --register, whether the app can register itself.

let arguments = Array(CommandLine.arguments.dropFirst())
guard let first = arguments.first, let url = MCPServerConfig.normalizedURL(first) else {
    print("usage: harness-mcp <url> [--register] [--call tool '{...}']")
    exit(2)
}
let connection = MCPConnection(url: url, credentials: nil)
do {
    let tools = try await connection.listTools()
    let config = MCPServerConfig(name: await connection.serverName ?? url.host ?? "server", url: url.absoluteString)
    print("\(config.name): \(tools.count) tools, no sign-in needed")
    var characters = 0
    for tool in tools {
        characters += tool.description.count + tool.inputSchema.jsonString.count
        print("  \(config.exposedName(for: tool.name))  \(tool.description.prefix(70).replacingOccurrences(of: "\n", with: " "))")
    }
    print("about \(characters / 4) tokens of tool descriptions")
    if let index = arguments.firstIndex(of: "--call"), index + 1 < arguments.count {
        let input = index + 2 < arguments.count ? JSONValue(jsonString: arguments[index + 2]) ?? [:] : [:]
        let result = try await connection.callTool(arguments[index + 1], arguments: input)
        print("\(result.isError ? "error" : "result"): \(result.text.prefix(600))")
    }
} catch MCPError.needsSignIn(let challenge) {
    print("sign-in needed; challenge: \(challenge ?? "none")")
    do {
        let flow = OAuthFlow()
        let info = try await flow.discover(serverURL: url, challenge: challenge)
        print("  resource:  \(info.resource)")
        print("  authorize: \(info.authorizationEndpoint)")
        print("  token:     \(info.tokenEndpoint)")
        print("  register:  \(info.registrationEndpoint?.absoluteString ?? "not offered")")
        print("  scopes:    \(info.scopes.joined(separator: " "))")
        if arguments.contains("--register") {
            let client = try await flow.register(info, redirectURI: "com.jflick.resident://oauth")
            print("  registered, client id \(client.clientID.prefix(12))…")
            print("  sign-in page: \(try flow.authorizationRequest(info, client: client, redirectURI: "com.jflick.resident://oauth").url.absoluteString.prefix(160))…")
        }
    } catch {
        print("  \(error.localizedDescription)")
    }
} catch {
    print("failed: \(error.localizedDescription)")
    exit(1)
}
