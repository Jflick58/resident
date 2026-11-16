import HarnessKit
import SwiftUI

/// Settings stay short: presets, memory, models. Everything else has a sensible default.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        PresetListView()
                    } label: {
                        LabeledContent {
                            Text("\(app.presets.count)")
                        } label: {
                            Label("Agents", systemImage: "person.2")
                        }
                    }
                    NavigationLink {
                        ConnectorsView()
                    } label: {
                        LabeledContent {
                            Text("\(app.connectors.servers.count + Connector.allCases.count)")
                        } label: {
                            Label("Connectors", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                    }
                    NavigationLink {
                        SkillsView()
                    } label: {
                        LabeledContent {
                            Text("\(app.skills.filter(\.isEnabled).count)")
                        } label: {
                            Label("Skills", systemImage: "book.closed")
                        }
                    }
                    NavigationLink {
                        MemoryView()
                    } label: {
                        LabeledContent {
                            Text(app.memoryEnabled ? "\(app.memory.facts.count)" : "Off")
                        } label: {
                            Label("Memory", systemImage: "brain")
                        }
                    }
                } footer: {
                    Text("An agent sets how the model behaves in a chat: its instructions, the tools it can use and how hard it thinks.")
                }

                if !app.library.installed.isEmpty {
                    Section {
                        ForEach(app.library.installed) { model in
                            NavigationLink {
                                ModelSettingsView(model: model)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.name)
                                    Text(ModelSettingsView.describe(app.sampling(for: model)).capitalizedFirst)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Model Settings")
                    } footer: {
                        Text("How each model on this device picks its words. An agent can set its own temperature instead.")
                    }
                }

                Section {
                    LabeledContent("Memory for Models", value: ModelFit.format(app.device.memoryBudgetBytes))
                    LabeledContent("Free Storage", value: ModelFit.format(app.device.freeDiskBytes))
                } header: {
                    Text("This Device")
                } footer: {
                    Text("Models run entirely on this device. Web search and page reading send only the search or address, and connectors only what a tool is asked, in agents where they are turned on.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct PresetListView: View {
    @Environment(AppModel.self) private var app
    @State private var newPreset: HarnessPreset?

    var body: some View {
        @Bindable var app = app
        List {
            Section {
                ForEach(app.presets) { preset in
                    NavigationLink {
                        PresetEditor(preset: preset)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: preset.symbol)
                                .frame(width: 28)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                Text(Self.toolSummary(preset))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .deleteDisabled(preset.isBuiltIn)
                }
                .onDelete { offsets in
                    for preset in offsets.map({ app.presets[$0] }) { app.delete(preset) }
                }
            }

            Section {
                Picker("New Chats Use", selection: $app.library.defaultPresetID) {
                    ForEach(app.presets) { Text($0.name).tag($0.id) }
                }
                .onChange(of: app.library.defaultPresetID) { app.store.save(app.library) }
            }
        }
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Agent", systemImage: "plus") {
                    newPreset = HarnessPreset(
                        name: "", symbol: "star", summary: "", systemPrompt: HarnessPreset.chat.systemPrompt,
                        tools: BuiltInTool.allCases)
                }
            }
        }
        .sheet(item: $newPreset) { preset in
            NavigationStack {
                PresetEditor(preset: preset, isNew: true)
            }
        }
    }

    static func toolSummary(_ preset: HarnessPreset) -> String {
        let names = preset.tools.map(\.title) + preset.connectors.map(\.title)
        return names.isEmpty ? "No tools" : names.joined(separator: ", ")
    }
}

/// One short form: name, instructions, a switch per tool and connector, and three pickers.
struct PresetEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var preset: HarnessPreset
    var isNew = false

    private static let symbols = [
        "sparkles", "bubble.left", "chevron.left.forwardslash.chevron.right", "star", "book", "globe",
        "pencil", "lightbulb", "graduationcap", "briefcase", "heart", "leaf",
    ]

    private static let lengths = [1024, 2048, 4096, 8192]

    /// Temperatures an agent can ask for, in tenths.
    private static let temperatures = (0...15).map { Double($0) / 10 }

    private var hasChanges: Bool {
        isNew || app.presets.first { $0.id == preset.id } != preset
    }

    private var isModifiedBuiltIn: Bool {
        guard let original = HarnessPreset.builtIns.first(where: { $0.id == preset.id }) else { return false }
        return original != app.presets.first { $0.id == preset.id }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $preset.name)
                Picker("Icon", selection: $preset.symbol) {
                    ForEach(Self.symbols, id: \.self) { symbol in
                        Image(systemName: symbol).tag(symbol)
                    }
                }
            }

            Section {
                TextField("Instructions", text: $preset.systemPrompt, axis: .vertical)
                    .lineLimit(4...12)
                    .font(.callout)
            } header: {
                Text("Instructions")
            } footer: {
                Text("Keep it short. Small models follow a few clear sentences better than a long brief.")
            }

            Section {
                ForEach(BuiltInTool.allCases) { tool in
                    Toggle(isOn: binding(for: tool)) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.title)
                                Text(tool.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: tool.symbol)
                        }
                    }
                }
            } header: {
                Text("Tools")
            } footer: {
                Text("Always in front of the model when switched on. With all of them off, nothing leaves this device.")
            }

            Section {
                ForEach(Connector.allCases) { connector in
                    Toggle(isOn: binding(for: connector)) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(connector.title)
                                Text(connector.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: connector.symbol)
                        }
                    }
                }
                ForEach(app.connectors.servers) { server in
                    Toggle(isOn: binding(for: server.id)) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                Text(server.needsSignIn ? "Sign in needed" : "\(server.enabledTools.count) tools from \(URL(string: server.url)?.host ?? server.url)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                        }
                    }
                }
            } header: {
                Text("Connectors")
            } footer: {
                Text("The model sees each connector as one line and opens a few of its tools when a request needs them. Calendar and Reminders stay on this device. Add more in Settings > Connectors.")
            }

            Section {
                Picker("Thinking", selection: $preset.thinking) {
                    ForEach(ThinkingLevel.allCases) { Text($0.title).tag($0) }
                }
                Picker("Max Reply Tokens", selection: $preset.maxOutputTokens) {
                    ForEach(Self.lengths, id: \.self) { Text($0.formatted()).tag($0) }
                }
                Picker("Temperature", selection: $preset.temperature) {
                    Text("Model's").tag(Double?.none)
                    ForEach(Self.temperatures, id: \.self) { Text(String(format: "%.1f", $0)).tag(Double?.some($0)) }
                }
            } footer: {
                Text("More thinking gives better answers to hard questions and slower ones to easy questions; it can also be changed in a chat. Higher temperature makes replies more varied. Left at Model's, the agent uses the temperature set for whichever model is answering (Settings > Model Settings).")
            }

            if isModifiedBuiltIn {
                Section {
                    Button("Reset to Default", role: .destructive) {
                        app.reset(preset)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(isNew ? "New Agent" : preset.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    preset.summary = isNew || !preset.isBuiltIn ? PresetListView.toolSummary(preset) : preset.summary
                    app.save(preset)
                    dismiss()
                }
                .disabled(!hasChanges || preset.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            // Snap stored values to the nearest offered choice so the pickers always show a selection.
            preset.maxOutputTokens = Self.lengths.min { abs($0 - preset.maxOutputTokens) < abs($1 - preset.maxOutputTokens) }!
            if let own = preset.temperature {
                preset.temperature = Self.temperatures.min { abs($0 - own) < abs($1 - own) }
            }
        }
    }

    private func binding(for server: UUID) -> Binding<Bool> {
        Binding(
            get: { preset.servers.contains(server) },
            set: { isOn in
                preset.servers.removeAll { $0 == server }
                if isOn { preset.servers.append(server) }
            })
    }

    private func binding(for connector: Connector) -> Binding<Bool> {
        Binding(
            get: { preset.connectors.contains(connector) },
            set: { isOn in
                if isOn {
                    if !preset.connectors.contains(connector) { preset.connectors.append(connector) }
                } else {
                    preset.connectors.removeAll { $0 == connector }
                }
            })
    }

    private func binding(for tool: BuiltInTool) -> Binding<Bool> {
        Binding(
            get: { preset.tools.contains(tool) },
            set: { isOn in
                if isOn {
                    if !preset.tools.contains(tool) { preset.tools.append(tool) }
                } else {
                    preset.tools.removeAll { $0 == tool }
                }
            })
    }
}

/// What the assistant remembers: plain facts the user can read, correct, remove or switch off.
struct MemoryView: View {
    @Environment(AppModel.self) private var app
    @State private var facts: [String] = []
    @State private var newFact = ""
    @State private var editing: EditedFact?
    @State private var confirmingClear = false

    struct EditedFact: Identifiable {
        var index: Int
        var text: String
        var id: Int { index }
    }

    var body: some View {
        @Bindable var app = app
        List {
            Section {
                Toggle("Remember Across Chats", isOn: $app.memoryEnabled)
            } footer: {
                Text(app.memoryEnabled
                    ? "These facts are given to the assistant at the start of every chat. It adds to them in agents where Memory is turned on, and you can ask it to forget something."
                    : "Memory is off. Nothing here is used in chats and nothing new is saved. Your saved facts are kept.")
            }

            Section {
                ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                    Button {
                        editing = EditedFact(index: index, text: fact)
                    } label: {
                        Text(fact).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    facts.remove(atOffsets: offsets)
                    save()
                }
                HStack {
                    TextField("Add something to remember", text: $newFact)
                        .onSubmit(add)
                    if !newFact.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("Add", action: add)
                    }
                }
            } header: {
                Text("Saved")
            } footer: {
                let used = facts.reduce(0) { $0 + $1.count + 3 }
                Text("Tap a fact to change it, swipe to remove it. \(used) of \(app.memory.maxCharacters) characters used; memory is kept small because all of it is read in every chat.")
            }
            .disabled(!app.memoryEnabled)

            if !facts.isEmpty {
                Section {
                    Button("Forget Everything", role: .destructive) { confirmingClear = true }
                }
            }
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { facts = app.memory.facts }
        .confirmationDialog("Forget everything the assistant remembers about you?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Forget Everything", role: .destructive) {
                facts = []
                save()
            }
        }
        .alert("Edit Memory", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Fact", text: Binding(get: { editing?.text ?? "" }, set: { editing?.text = $0 }))
            Button("Save") {
                if let editing, facts.indices.contains(editing.index) {
                    let text = editing.text.trimmingCharacters(in: .whitespaces)
                    if text.isEmpty { facts.remove(at: editing.index) } else { facts[editing.index] = text }
                    save()
                }
                editing = nil
            }
            Button("Cancel", role: .cancel) { editing = nil }
        }
    }

    private func add() {
        let fact = newFact.trimmingCharacters(in: .whitespaces)
        guard !fact.isEmpty else { return }
        facts.append(fact)
        newFact = ""
        save()
    }

    private func save() {
        app.memory.setFacts(facts)
    }
}

extension String {
    /// The same text with its first letter in upper case.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
