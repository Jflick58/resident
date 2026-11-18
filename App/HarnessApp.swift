import HarnessKit
import SwiftUI

@main
struct HarnessApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var app = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                // A long agent run should not be cut off by the screen locking itself.
                .onChange(of: app.isGenerating, initial: true) {
                    UIApplication.shared.isIdleTimerDisabled = app.isGenerating
                }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background { app.didEnterBackground() }
            if scenePhase == .active { app.didBecomeActive() }
        }
    }
}

/// The app is one screen: the current chat. Everything else is a sheet over it.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var currentID: UUID?
    @State private var sheet: Sheet?

    enum Sheet: String, Identifiable {
        case chats, models, settings, presets
        #if DEBUG
            case hub, presetEditor, connectors, addConnector, connectorDetail, skills, memory
        #endif
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let currentID, let chat = app.chatModel(for: currentID) {
                    ChatView(chat: chat, showModels: { sheet = .models }, showPresets: { sheet = .presets })
                        .id(currentID)
                } else {
                    Color.clear
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Chats", systemImage: "sidebar.left") { sheet = .chats }
                }
                ToolbarItem(placement: .principal) {
                    ModelMenu(showModels: { sheet = .models })
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { sheet = .settings }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Chat", systemImage: "square.and.pencil") {
                        currentID = app.newConversation()
                    }
                }
            }
        }
        .onChange(of: app.openConversation, initial: true) {
            if let id = app.openConversation {
                currentID = id
                sheet = nil
                app.openConversation = nil
            }
        }
        .onAppear {
            if currentID == nil { currentID = app.newConversation() }
            #if DEBUG
                applyLaunchArguments()
            #endif
        }
        .sheet(item: Binding(get: { app.skillProposal }, set: { if $0 == nil { app.answerProposal(nil) } })) { proposal in
            SkillProposalView(skill: proposal.skill)
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .chats:
                ChatListView(currentID: $currentID, showSettings: { self.sheet = .settings })
            case .models:
                ModelsView()
            case .settings:
                SettingsView()
            #if DEBUG
                case .hub:
                    NavigationStack {
                        AddFromHubView(initialLink: UserDefaults.standard.string(forKey: "hubLink") ?? "")
                    }
                case .presetEditor:
                    NavigationStack { PresetEditor(preset: app.presets[0]) }
                case .connectors:
                    NavigationStack { ConnectorsView() }
                case .addConnector:
                    NavigationStack { AddConnectorView() }
                case .skills:
                    NavigationStack { SkillsView() }
                case .memory:
                    NavigationStack { MemoryView() }
                case .connectorDetail:
                    NavigationStack {
                        if let server = app.connectors.servers.last { ConnectorDetailView(id: server.id) }
                    }
            #endif
            case .presets:
                NavigationStack {
                    PresetListView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { self.sheet = nil }
                            }
                        }
                }
            }
        }
    }
}

#if DEBUG
    extension RootView {
        /// Launch arguments for driving the app from the command line while developing:
        /// `-openSheet models|chats|settings|presets|hub|presetEditor|connectors|addConnector|connectorDetail`, `-hubLink <link>`, `-addServer "Name|url|model"`, `-openLatestChat YES`, `-continueTurn YES`, `-addConnector <url>`, `-installRepo owner/name` and `-demoPrompt "text"`.
        fileprivate func applyLaunchArguments() {
            let defaults = UserDefaults.standard
            if let name = defaults.string(forKey: "openSheet") { sheet = Sheet(rawValue: name) }
            // -addServer "Name|http://host:port/v1|model"
            if let server = defaults.string(forKey: "addServer") {
                let parts = server.components(separatedBy: "|")
                if parts.count == 3 {
                    let existing = app.library.endpoints.first { $0.name == parts[0] }
                    var endpoint = existing ?? RemoteEndpoint(name: parts[0], baseURL: parts[1], model: parts[2])
                    endpoint.baseURL = parts[1]
                    endpoint.model = parts[2]
                    app.save(endpoint)
                    app.select(.remote(endpoint.id))
                }
            }
            // -addConnector <url>: add an MCP server, as typing its address would.
            if let address = defaults.string(forKey: "addConnector") {
                Task {
                    do { try await app.addConnector(address: address) } catch { print("addConnector failed: \(error.localizedDescription)") }
                }
            }
            // -installRepo owner/name: start a model download, as tapping Get would.
            if let repo = defaults.string(forKey: "installRepo"), !app.isInstalled(repo) {
                Task {
                    guard let info = try? await HubMetadataClient().info(repo: repo) else { return }
                    let report = ModelFit.evaluate(info, device: app.device)
                    if report.canInstall {
                        app.install(info, name: AddFromHubView.displayName(for: repo), report: report)
                    }
                }
            }
            // -openLatestChat YES
            if defaults.bool(forKey: "openLatestChat"), let latest = app.conversations.first(where: { !$0.isEmpty }) {
                currentID = latest.id
            }
            // -continueTurn YES: carry on with the open chat's unfinished turn.
            if defaults.bool(forKey: "continueTurn"), let currentID, let chat = app.chatModel(for: currentID) {
                chat.continueTurn()
            }
            // -demoModel <part of its name>: answer with that installed model.
            if let wanted = defaults.string(forKey: "demoModel")?.lowercased(),
                let model = app.library.installed.first(where: { $0.name.lowercased().contains(wanted) || $0.repo.lowercased().contains(wanted) })
            {
                app.select(.local(model.repo))
            }
            // -weightMap shared|private: how a mapped model's weights are mapped, to measure one way against the other.
            if let map = defaults.string(forKey: "weightMap") { AppModel.setSharesWeightPages(map == "shared") }
            if let prompt = defaults.string(forKey: "demoPrompt"), let currentID,
                let chat = app.chatModel(for: currentID), chat.conversation.isEmpty
            {
                // -demoFollowUps "second|third": sent one at a time, each when the reply before it has ended.
                let followUps = defaults.string(forKey: "demoFollowUps")?.components(separatedBy: "|") ?? []
                defer {
                    if !followUps.isEmpty {
                        Task {
                            for text in followUps {
                                // The first message may still be on its way in, when a file is read for it.
                                while chat.conversation.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
                                await chat.waitForTurn()
                                chat.send(text)
                            }
                        }
                    }
                }
                // -demoThinking off|low|medium|high: how hard to think in that chat.
                if let level = defaults.string(forKey: "demoThinking").flatMap(ThinkingLevel.init(rawValue:)) { chat.setThinking(level) }
                // -attachFile <path>: send the prompt with a file attached, as picking it would.
                if let path = defaults.string(forKey: "attachFile") {
                    Task {
                        switch try? await DocumentReader.read(URL(fileURLWithPath: path)) {
                        case .document(let document): chat.send(prompt, documents: [document])
                        case .image(let data):
                            var photo = ComposerView.attachment(from: data)
                            photo?.recognizedText = await DocumentReader.recognizeText(in: data)
                            chat.send(prompt, images: photo.map { [$0] } ?? [])
                        case nil: chat.send(prompt + " (the file could not be read)")
                        }
                    }
                } else {
                    chat.send(prompt)
                }
            }
        }
    }
#endif

/// The title of the chat screen: which model is answering, and a way to switch.
struct ModelMenu: View {
    @Environment(AppModel.self) private var app
    var showModels: () -> Void

    var body: some View {
        Menu {
            Picker("Model", selection: Binding(get: { app.library.selected }, set: { if let ref = $0 { app.select(ref) } })) {
                ForEach(app.library.installed) { model in
                    Label(model.name, systemImage: "iphone").tag(ModelRef?.some(.local(model.repo)))
                }
                ForEach(app.library.endpoints) { endpoint in
                    Label(endpoint.name, systemImage: "network").tag(ModelRef?.some(.remote(endpoint.id)))
                }
                if app.appleModelIssue == nil {
                    Label("Apple Intelligence", systemImage: "apple.intelligence").tag(ModelRef?.some(.apple))
                }
                if app.isSimulator {
                    Label("Demo Model", systemImage: "theatermasks").tag(ModelRef?.some(.demo))
                }
            }
            Divider()
            Button("Manage Models…", systemImage: "square.and.arrow.down", action: showModels)
        } label: {
            HStack(spacing: 4) {
                Text(app.name(of: app.library.selected))
                    .font(.headline)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
        }
    }
}
