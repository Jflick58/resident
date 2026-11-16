import HarnessKit
import SwiftUI

/// Services known to work with this app's sign-in, offered as one-tap choices.
struct SuggestedConnector: Identifiable {
    var name: String
    var url: String
    var detail: String
    var symbol: String
    /// Set for services where the app cannot register itself: what to tell the user to bring.
    var clientIDHint: String?
    /// The Info.plist keys of a client ID and secret built into this copy of the app, for such services.
    var builtInKeys: (id: String, secret: String?)?
    /// True when the service lets the user sign in by typing a code at its site, so no client secret is needed.
    var offersCode = false
    var scopes: [String]?
    /// Tools left on when the service has more than a small model should be shown.
    var onlyTools: [String]?
    var id: String { url }

    /// The client built into this copy of the app, if its maker set one.
    var builtInClient: (id: String, secret: String)? {
        func value(_ key: String?) -> String {
            guard let key else { return "" }
            return (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "").trimmingCharacters(in: .whitespaces)
        }
        guard let keys = builtInKeys, !value(keys.id).isEmpty else { return nil }
        return (value(keys.id), value(keys.secret))
    }

    private static let googleHint =
        "needs a Google client ID. Create an iOS OAuth client for bundle ID \(AppIdentity.bundleID) in Google Cloud, then enter its ID under Advanced and tap again."

    static let all = [
        SuggestedConnector(
            name: "Gmail", url: "https://gmailmcp.googleapis.com/mcp/v1", detail: "Search and read mail, write drafts", symbol: "envelope",
            clientIDHint: "Gmail " + googleHint, builtInKeys: ("GoogleClientID", nil),
            scopes: ["https://www.googleapis.com/auth/gmail.readonly", "https://www.googleapis.com/auth/gmail.compose"],
            onlyTools: ["search_threads", "get_thread", "create_draft"]),
        SuggestedConnector(
            name: "Google Calendar", url: "https://calendarmcp.googleapis.com/mcp/v1", detail: "Events across your Google calendars", symbol: "calendar",
            clientIDHint: "Google Calendar " + googleHint, builtInKeys: ("GoogleClientID", nil),
            onlyTools: ["list_events", "create_event", "update_event", "delete_event", "suggest_time"]),
        SuggestedConnector(
            name: "GitHub", url: "https://api.githubcopilot.com/mcp/", detail: "Repositories, issues and pull requests",
            symbol: "chevron.left.forwardslash.chevron.right",
            clientIDHint:
                "GitHub needs a client ID. Create an OAuth app at github.com/settings/developers with the callback \(ConnectorsModel.redirectURI), tick Enable Device Flow, then enter its ID under Advanced and tap again.",
            builtInKeys: ("GitHubClientID", nil), offersCode: true),
        SuggestedConnector(name: "Linear", url: "https://mcp.linear.app/mcp", detail: "Issues and projects", symbol: "checklist"),
        SuggestedConnector(name: "Notion", url: "https://mcp.notion.com/mcp", detail: "Pages and databases", symbol: "doc.text"),
        SuggestedConnector(name: "Atlassian", url: "https://mcp.atlassian.com/v1/mcp", detail: "Jira and Confluence", symbol: "square.stack.3d.up"),
        SuggestedConnector(name: "Sentry", url: "https://mcp.sentry.dev/mcp", detail: "Errors in your apps", symbol: "exclamationmark.triangle"),
        SuggestedConnector(name: "Hugging Face", url: "https://huggingface.co/mcp", detail: "Models, datasets and Spaces", symbol: "cube"),
        SuggestedConnector(name: "DeepWiki", url: "https://mcp.deepwiki.com/mcp", detail: "Ask about any public GitHub repository", symbol: "book"),
    ]
}

/// Shows the code to type at a service's site, for sign-in that works that way.
private struct SignInCodeAlert: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        let code = app.connectors.signInCode
        content.alert(
            "Your Code: \(code?.code ?? "")",
            isPresented: Binding(get: { app.connectors.signInCode != nil }, set: { if !$0 { app.connectors.answerSignInCode(false) } })
        ) {
            Button("Continue") { app.connectors.answerSignInCode(true) }
            Button("Cancel", role: .cancel) { app.connectors.answerSignInCode(false) }
        } message: {
            Text("Enter this code at \(code?.site ?? "the site") to sign in. It has been copied, so you can paste it.")
        }
    }
}

/// The connectors the user has added, and the way to add more.
struct ConnectorsView: View {
    @Environment(AppModel.self) private var app
    @State private var isAdding = false

    var body: some View {
        List {
            Section {
                ForEach(app.connectors.servers) { server in
                    NavigationLink {
                        ConnectorDetailView(id: server.id)
                    } label: {
                        ConnectorRow(server: server)
                    }
                }
                .onDelete { offsets in
                    for server in offsets.map({ app.connectors.servers[$0] }) { app.removeConnector(server.id) }
                }
                Button("Add Connector", systemImage: "plus") { isAdding = true }
            } footer: {
                Text("Connectors let the assistant work with services you use, through the Model Context Protocol (MCP). Only what a tool is asked, and its answer, pass between this device and that service.")
            }

            Section {
                ForEach(Connector.allCases) { connector in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(connector.title)
                            Text(connector.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: connector.symbol)
                    }
                }
            } header: {
                Text("On This Device")
            } footer: {
                Text("Built in. Switch connectors on or off for each agent.")
            }
        }
        .navigationTitle("Connectors")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isAdding) {
            NavigationStack { AddConnectorView() }
        }
    }
}

private struct ConnectorRow: View {
    let server: MCPServerConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(server.name)
            if server.needsSignIn {
                Text("Sign in needed").font(.footnote).foregroundStyle(.orange)
            } else {
                let count = server.enabledTools.count
                Text("\(count) \(count == 1 ? "tool" : "tools") · \(URL(string: server.url)?.host ?? server.url)")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// Pick a known service or type an address. Sign-in, if the service wants it, opens by itself.
struct AddConnectorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var connecting: String?
    @State private var error: String?

    private var suggestions: [SuggestedConnector] {
        SuggestedConnector.all.filter { suggestion in !app.connectors.servers.contains { $0.url == suggestion.url } }
    }

    var body: some View {
        Form {
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                }
            }

            Section {
                ForEach(suggestions) { suggestion in
                    Button {
                        if let hint = suggestion.clientIDHint, suggestion.builtInClient == nil,
                            clientID.trimmingCharacters(in: .whitespaces).isEmpty
                        {
                            error = hint
                        } else {
                            connect(suggestion.url, name: suggestion.name, suggestion: suggestion)
                        }
                    } label: {
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.name).foregroundStyle(.primary)
                                    Text(suggestion.detail).font(.footnote).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: suggestion.symbol)
                            }
                            Spacer()
                            if connecting == suggestion.url { ProgressView() }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Suggested")
            }

            Section {
                TextField("https://example.com/mcp", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { connect(address) }
                Button {
                    connect(address)
                } label: {
                    HStack {
                        Text("Connect")
                        Spacer()
                        if connecting == address, !address.isEmpty { ProgressView() }
                    }
                }
                .disabled(MCPServerConfig.normalizedURL(address) == nil)
            } header: {
                Text("Other Service")
            } footer: {
                Text("Any MCP server reachable over the web. If it asks you to sign in, its own sign-in page opens; this app never sees your password.")
            }

            Section {
                TextField("Client ID", text: $clientID)
                SecureField("Client Secret (if the service gave one)", text: $clientSecret)
            } header: {
                Text("Advanced")
            } footer: {
                Text("Leave empty unless the service says apps cannot register themselves, as Google and GitHub do. Create an OAuth client in that service's developer settings (for GitHub, with the callback \(ConnectorsModel.redirectURI)) and enter its details here.")
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .disabled(connecting != nil)
        .navigationTitle("Add Connector")
        .modifier(SignInCodeAlert())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private func connect(_ url: String, name: String = "", suggestion: SuggestedConnector? = nil) {
        guard connecting == nil else { return }
        connecting = url
        error = nil
        // What the user typed under Advanced wins over the client built into the app.
        let typed = !clientID.trimmingCharacters(in: .whitespaces).isEmpty
        let builtIn = typed ? nil : suggestion?.builtInClient
        let secret = builtIn?.secret ?? clientSecret
        // With no secret to hand, a service that offers it is signed in to with a code typed at its site.
        let withCode = suggestion?.offersCode == true && secret.trimmingCharacters(in: .whitespaces).isEmpty
        Task {
            defer { connecting = nil }
            do {
                try await app.addConnector(
                    address: url, name: name, clientID: builtIn?.id ?? clientID, clientSecret: secret,
                    scopes: suggestion?.scopes,
                    onlyTools: suggestion?.onlyTools, signInFirst: suggestion?.clientIDHint != nil, withCode: withCode, summary: suggestion?.detail)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// One connector: its state, its tools with a switch each, and the way out.
struct ConnectorDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        if let server = app.connectors.server(id) {
            List {
                Section {
                    LabeledContent("Address", value: server.url)
                    if server.needsSignIn {
                        Button("Sign In") { run { try await app.connectors.signIn(id) } }
                    } else {
                        Button("Check for New Tools") { run { try await app.connectors.refreshTools(id) } }
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    }
                } footer: {
                    if server.needsSignIn { Text("This connector cannot be used until you sign in.") }
                }

                Section {
                    ForEach(server.tools) { tool in
                        Toggle(isOn: Binding(
                            get: { !server.disabledTools.contains(tool.name) },
                            set: { app.connectors.setTool(tool.name, enabled: $0, in: id) })
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(MCPTool.readableName(tool).capitalized)
                                Text(tool.description.trimmingCharacters(in: .whitespacesAndNewlines))
                                    .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Tools")
                        Spacer()
                        if server.tools.count > 1 {
                            let allOn = server.disabledTools.isEmpty
                            Button(allOn ? "Turn All Off" : "Turn All On") {
                                app.connectors.setAllTools(enabled: !allOn, in: id)
                            }
                            .font(.footnote)
                            .textCase(nil)
                        }
                    }
                } footer: {
                    Text("Small models choose better among fewer tools. Turn off the ones you will not use.")
                }

                Section {
                    if server.isSignedIn, !server.needsSignIn {
                        Button("Sign Out") { app.connectors.signOut(id) }
                    }
                    Button("Remove Connector", role: .destructive) {
                        app.removeConnector(id)
                        dismiss()
                    }
                }
            }
            .disabled(isWorking)
            .overlay { if isWorking { ProgressView() } }
            .navigationTitle(server.name)
            .modifier(SignInCodeAlert())
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                try await work()
            } catch MCPError.needsSignIn {
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
