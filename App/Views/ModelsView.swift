import HarnessKit
import SwiftUI

/// Everything about models in one list: what is installed, what is worth
/// installing on this device, adding any Hugging Face model, and servers.
struct ModelsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var editingEndpoint: RemoteEndpoint?

    private var recommended: [(model: CatalogModel, report: FitReport)] {
        ModelCatalog.recommended(on: app.device).filter { !app.isInstalled($0.model.repo) }
    }

    @State private var tuning: InstalledModel?

    var body: some View {
        NavigationStack {
            List {
                if app.hasAppleModel {
                    Section {
                        Button {
                            app.select(.apple)
                        } label: {
                            ModelRow(
                                name: "Apple Intelligence", detail: app.appleModelIssue ?? "Nothing to download",
                                capabilities: app.appleModelIssue == nil ? .init(vision: false, tools: true, thinking: false) : nil,
                                isSelected: app.library.selected == .apple)
                        }
                        .tint(.primary)
                        .disabled(app.appleModelIssue != nil)
                    } header: {
                        Text("Built In")
                    } footer: {
                        Text("The model that comes with this device, run by the system. It answers fast and can work while Resident is not on screen, and takes less text at once than a downloaded model.")
                    }
                }

                if !app.library.installed.isEmpty {
                    Section {
                        ForEach(app.library.installed) { model in
                            HStack(spacing: 12) {
                                Button {
                                    app.select(.local(model.repo))
                                } label: {
                                    ModelRow(
                                        name: model.name, detail: ModelFit.format(model.sizeBytes),
                                        capabilities: model.capabilities,
                                        isSelected: app.library.selected == .local(model.repo))
                                }
                                .tint(.primary)
                                Button {
                                    tuning = model
                                } label: {
                                    Image(systemName: "slider.horizontal.3")
                                        .frame(width: 36, height: 36)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel("Settings for \(model.name)")
                            }
                            // Two buttons in one row: each answers only its own taps.
                            .buttonStyle(.borderless)
                            .swipeActions {
                                Button("Delete", role: .destructive) { app.remove(model) }
                            }
                        }
                    } header: {
                        Text("On This Device")
                    } footer: {
                        Text("Tap a model to use it. The sliders button opens its settings: temperature, top P and repeat penalty.")
                    }
                }

                if !recommended.isEmpty {
                    Section {
                        ForEach(recommended, id: \.model.id) { item in
                            CatalogRow(model: item.model, report: item.report)
                        }
                    } header: {
                        Text("Recommended")
                    } footer: {
                        Text("Tested models that fit this device. Larger ones are left out.")
                    }
                }

                Section {
                    NavigationLink {
                        AddFromHubView()
                    } label: {
                        Label("Add from Hugging Face", systemImage: "link")
                    }
                } footer: {
                    Text("Paste a link to any MLX model. It is checked against this device before anything downloads.")
                }

                Section {
                    ForEach(app.library.endpoints) { endpoint in
                        Button {
                            app.select(.remote(endpoint.id))
                        } label: {
                            ModelRow(
                                name: endpoint.name, detail: endpoint.model, capabilities: nil,
                                isSelected: app.library.selected == .remote(endpoint.id))
                        }
                        .tint(.primary)
                        .swipeActions {
                            Button("Delete", role: .destructive) { app.remove(endpoint) }
                            Button("Edit") { editingEndpoint = endpoint }
                        }
                    }
                    Button {
                        editingEndpoint = RemoteEndpoint(name: "", baseURL: "", model: "")
                    } label: {
                        Label("Add Server", systemImage: "plus")
                    }
                } header: {
                    Text("Servers")
                } footer: {
                    Text("Any OpenAI-compatible server, such as Ollama or LM Studio on your Mac.")
                }
            }
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $tuning) { ModelSettingsView(model: $0) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editingEndpoint) { endpoint in
                ServerEditor(endpoint: endpoint)
            }
        }
    }
}

struct ModelRow: View {
    let name: String
    let detail: String
    let capabilities: ModelCapabilities?
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).foregroundStyle(.primary)
                HStack(spacing: 8) {
                    Text(detail)
                    if let capabilities { CapabilityIcons(capabilities: capabilities) }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
            }
        }
        .contentShape(Rectangle())
    }
}

struct CapabilityIcons: View {
    let capabilities: ModelCapabilities

    var body: some View {
        HStack(spacing: 6) {
            if capabilities.vision { Image(systemName: "eye").accessibilityLabel("Sees images") }
            if capabilities.tools { Image(systemName: "wrench.and.screwdriver").accessibilityLabel("Uses tools") }
            if capabilities.thinking { Image(systemName: "brain").accessibilityLabel("Can think") }
        }
        .imageScale(.small)
    }
}

struct CatalogRow: View {
    @Environment(AppModel.self) private var app
    let model: CatalogModel
    let report: FitReport
    @State private var isPreparing = false
    @State private var error: String?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name)
                Text(model.blurb)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(ModelFit.format(model.weightBytes))
                    CapabilityIcons(capabilities: model.capabilities)
                    if report.verdict == .tight {
                        Text("Shorter chats").foregroundStyle(.orange)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                if let message = error ?? app.downloads[model.repo]?.error {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
            Spacer()
            DownloadButton(
                state: app.downloads[model.repo], isPreparing: isPreparing,
                start: start, cancel: { app.cancelDownload(model.repo) })
        }
    }

    private func start() {
        error = nil
        if app.downloads[model.repo]?.error != nil {
            app.retryDownload(model.repo)
            return
        }
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do {
                // The file list comes from the Hub so the download matches the repository exactly.
                let info = try await HubMetadataClient().info(repo: model.repo)
                var live = ModelFit.evaluate(info, device: app.device)
                live.capabilities = model.capabilities
                guard live.canInstall else {
                    error = live.detail
                    return
                }
                app.install(info, name: model.name, report: live)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct DownloadButton: View {
    let state: AppModel.DownloadState?
    let isPreparing: Bool
    var start: () -> Void
    var cancel: () -> Void

    var body: some View {
        if let state, state.error == nil {
            Button(action: cancel) {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 3)
                    Circle().trim(from: 0, to: max(0.02, state.fraction))
                        .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "stop.fill").font(.system(size: 9))
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel("Cancel download, \(Int(state.fraction * 100)) percent done")
        } else if isPreparing {
            ProgressView().frame(width: 28, height: 28)
        } else {
            Button(state?.error == nil ? "Get" : "Retry", action: start)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .fontWeight(.semibold)
        }
    }
}

/// Paste a link, see whether it will run here, then download.
struct AddFromHubView: View {
    @Environment(AppModel.self) private var app
    /// A link to check as soon as the screen opens.
    var initialLink = ""
    @State private var link = ""
    @State private var isChecking = false
    @State private var info: HubModelInfo?
    @State private var report: FitReport?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("huggingface.co/mlx-community/…", text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit(check)
                Button(action: check) {
                    HStack {
                        Text("Check Model")
                        if isChecking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || isChecking)
            } footer: {
                Text("Works with models converted for MLX. Most are published by mlx-community.")
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                }
            }

            if let info, let report {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(report.headline, systemImage: symbol(for: report.verdict))
                            .font(.headline)
                            .foregroundStyle(color(for: report.verdict))
                        Text(report.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    LabeledContent("Model", value: info.repo)
                    if report.downloadBytes > 0 {
                        LabeledContent("Download", value: ModelFit.format(report.downloadBytes))
                    }
                    if report.canInstall {
                        LabeledContent("Abilities") { CapabilityIcons(capabilities: report.capabilities) }
                    }
                }

                if report.canInstall {
                    Section {
                        if app.isInstalled(info.repo) {
                            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if let download = app.downloads[info.repo], download.error == nil {
                            ProgressView(value: download.fraction) {
                                Text("Downloading").font(.subheadline)
                            }
                            Button("Cancel", role: .destructive) { app.cancelDownload(info.repo) }
                        } else {
                            Button(app.downloads[info.repo]?.error == nil ? "Download" : "Try Again") {
                                if app.downloads[info.repo]?.error != nil {
                                    app.retryDownload(info.repo)
                                } else {
                                    app.install(info, name: Self.displayName(for: info.repo), report: report)
                                }
                            }
                            .fontWeight(.semibold)
                            if let message = app.downloads[info.repo]?.error {
                                Text(message).font(.footnote).foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Add from Hugging Face")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if link.isEmpty, !initialLink.isEmpty {
                link = initialLink
                check()
            }
        }
    }

    private func check() {
        error = nil
        info = nil
        report = nil
        guard let repo = ModelFit.repoID(from: link) else {
            error = "That doesn't look like a Hugging Face model link. It should end in owner/model-name."
            return
        }
        isChecking = true
        Task {
            defer { isChecking = false }
            do {
                let fetched = try await HubMetadataClient().info(repo: repo)
                info = fetched
                report = ModelFit.evaluate(fetched, device: app.device)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    static func displayName(for repo: String) -> String { ModelCatalog.displayName(for: repo) }

    private func symbol(for verdict: FitVerdict) -> String {
        switch verdict {
        case .runsWell: return "checkmark.circle.fill"
        case .tight: return "exclamationmark.circle.fill"
        case .wontRun, .unsupported: return "xmark.circle.fill"
        }
    }

    private func color(for verdict: FitVerdict) -> Color {
        switch verdict {
        case .runsWell: return .green
        case .tight: return .orange
        case .wontRun, .unsupported: return .red
        }
    }
}

struct ServerEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var endpoint: RemoteEndpoint
    @State private var models: [String] = []
    @State private var isLoading = false
    @State private var error: String?

    private var canSave: Bool {
        endpoint.normalizedBaseURL != nil && !endpoint.model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $endpoint.name)
                    TextField("Address", text: $endpoint.baseURL, prompt: Text("http://192.168.1.20:11434/v1"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("API Key (optional)", text: $endpoint.apiKey)
                } footer: {
                    Text("The address ends in /v1 for most servers.")
                }

                Section("Model") {
                    if models.isEmpty {
                        TextField("Model name", text: $endpoint.model)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        Picker("Model", selection: $endpoint.model) {
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Button(action: loadModels) {
                        HStack {
                            Text("Find Models on Server")
                            if isLoading {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(endpoint.normalizedBaseURL == nil || isLoading)
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if endpoint.name.trimmingCharacters(in: .whitespaces).isEmpty {
                            endpoint.name = endpoint.model
                        }
                        app.save(endpoint)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private func loadModels() {
        error = nil
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let found = try await OpenAICompatibleProvider.listModels(endpoint: endpoint)
                if found.isEmpty {
                    error = "The server is reachable but lists no models."
                } else {
                    models = found
                    if !found.contains(endpoint.model) { endpoint.model = found[0] }
                }
            } catch {
                self.error = "Could not reach the server. \(error.localizedDescription)"
            }
        }
    }
}

/// The technical settings of one model: how it picks its words. They start at
/// the values the model's maker recommends, and most people never change them.
struct ModelSettingsView: View {
    @Environment(AppModel.self) private var app
    let model: InstalledModel
    @State private var sampling = SamplingSettings.standard
    @State private var penalizesRepeats = false

    private var maker: SamplingSettings { app.makerSampling(for: model) }

    private func use(_ settings: SamplingSettings) {
        sampling = settings
        penalizesRepeats = settings.repetitionPenalty != nil
    }

    static func describe(_ settings: SamplingSettings) -> String {
        var parts = [String(format: "temperature %.2f", settings.temperature), String(format: "top P %.2f", settings.topP)]
        if let penalty = settings.repetitionPenalty { parts.append(String(format: "repeat penalty %.2f", penalty)) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Temperature") {
                    Stepper(String(format: "%.2f", sampling.temperature), value: $sampling.temperature, in: 0...2, step: 0.05)
                }
                LabeledContent("Top P") {
                    Stepper(String(format: "%.2f", sampling.topP), value: $sampling.topP, in: 0.05...1, step: 0.05)
                }
                Toggle("Repeat Penalty", isOn: $penalizesRepeats)
                if penalizesRepeats {
                    LabeledContent("Strength") {
                        Stepper(
                            String(format: "%.2f", sampling.repetitionPenalty ?? 1.1),
                            value: Binding(get: { sampling.repetitionPenalty ?? 1.1 }, set: { sampling.repetitionPenalty = $0 }),
                            in: 1.05...2, step: 0.05)
                    }
                }
            } header: {
                Text("Sampling")
            } footer: {
                Text("Higher temperature makes replies more varied and less predictable. Top P cuts off unlikely words. A repeat penalty discourages saying the same thing again. An agent can set its own temperature, which is then used instead of this one.")
            }

            Section {
                LabeledContent("Context", value: "\(model.contextTokens.formatted()) tokens")
                LabeledContent("Size", value: ModelFit.format(model.sizeBytes))
                LabeledContent("Source", value: model.repo)
            }

            if maker != .standard, sampling != maker {
                Section {
                    Button("Use the Maker's Settings") { use(maker) }
                } footer: {
                    Text("What this model's maker ships it with: \(Self.describe(maker)).")
                }
            }
            if sampling != .standard {
                Section {
                    Button("Reset to Default") { use(.standard) }
                }
            }
        }
        .navigationTitle(model.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            sampling = app.sampling(for: model)
            penalizesRepeats = sampling.repetitionPenalty != nil
        }
        .onChange(of: penalizesRepeats) {
            sampling.repetitionPenalty = penalizesRepeats ? (sampling.repetitionPenalty ?? 1.1) : nil
        }
        .onChange(of: sampling) {
            app.setSampling(sampling == .standard ? nil : sampling, for: model.repo)
        }
    }
}
