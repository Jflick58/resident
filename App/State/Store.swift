import Foundation
import HarnessKit
import Security

struct Conversation: Codable, Identifiable, Hashable {
    var id = UUID()
    var title = "New Chat"
    var presetID: UUID
    var messages: [Message] = []
    var updatedAt = Date()
    /// True while a turn is unfinished. Saved with the chat, so a turn cut off by
    /// the app closing can be picked up again.
    var turnInProgress: Bool?
    /// True when the last turn stopped at its limit of steps with work still to do. It can be carried on.
    var reachedStepLimit: Bool?
    /// Connector tools the model has opened in this chat, so they stay declared.
    var loadedTools: [String]?
    /// How hard to think in this chat, when it differs from the agent's setting.
    var thinking: ThinkingLevel?
    /// Facts put in memory after a message, by that message's id, to show under it.
    var remembered: [String: [String]]?
    /// True once the chat has a name of its own, written by the model or the user.
    var isTitled: Bool?
    /// A summary standing in for the older part of a long chat, and the last message it covers.
    /// The messages themselves stay, and stay on screen; the model is given the summary instead.
    var summary: String?
    var summarizedThrough: UUID?

    /// The messages the model is given: those after the summarised part.
    var liveMessages: [Message] {
        guard activeSummary != nil, let index = messages.firstIndex(where: { $0.id == summarizedThrough }) else {
            return messages
        }
        return Array(messages[(index + 1)...])
    }

    /// The summary, while the messages it covers are still in the chat. Editing
    /// or regenerating from inside the summarised part removes them, and the summary with them.
    var activeSummary: String? {
        guard let summary, let id = summarizedThrough, messages.contains(where: { $0.id == id }) else { return nil }
        return summary
    }

    var isEmpty: Bool { messages.isEmpty }
}

/// A model downloaded to this device.
struct InstalledModel: Codable, Identifiable, Hashable {
    var repo: String
    var name: String
    var sizeBytes: Int64
    var contextTokens: Int
    var capabilities: ModelCapabilities
    /// The user's own sampling settings, when they differ from the model's.
    var sampling: SamplingSettings?

    var id: String { repo }
}

/// Which model a chat talks to.
enum ModelRef: Codable, Hashable {
    case local(String)
    case remote(UUID)
    /// The model built into the system (Apple Intelligence). Nothing to download.
    case apple
    /// A scripted stand-in, offered only in the simulator where MLX cannot run.
    case demo
}

struct Library: Codable {
    var installed: [InstalledModel] = []
    var endpoints: [RemoteEndpoint] = []
    var selected: ModelRef?
    var defaultPresetID: UUID = HarnessPreset.assistantID
}

/// Plain JSON files in Application Support. Small, inspectable, and easy to back up.
struct Store {
    let root: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("Harness", isDirectory: true)
        try? FileManager.default.createDirectory(at: conversationsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    var conversationsDirectory: URL { root.appendingPathComponent("conversations", isDirectory: true) }
    var modelsDirectory: URL { root.appendingPathComponent("models", isDirectory: true) }
    var memoryURL: URL { root.appendingPathComponent("memory.md") }

    func modelDirectory(for repo: String) -> URL {
        modelsDirectory.appendingPathComponent(ModelDownloader.folderName(for: repo), isDirectory: true)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func loadConversations() -> [Conversation] {
        let files = (try? FileManager.default.contentsOfDirectory(at: conversationsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { read(Conversation.self, from: $0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ conversation: Conversation) {
        write(conversation, to: conversationsDirectory.appendingPathComponent("\(conversation.id.uuidString).json"))
    }

    func delete(_ conversation: Conversation) {
        try? FileManager.default.removeItem(
            at: conversationsDirectory.appendingPathComponent("\(conversation.id.uuidString).json"))
    }

    func loadPresets() -> [HarnessPreset]? { read([HarnessPreset].self, from: root.appendingPathComponent("presets.json")) }
    func save(_ presets: [HarnessPreset]) { write(presets, to: root.appendingPathComponent("presets.json")) }

    func loadServers() -> [MCPServerConfig] { read([MCPServerConfig].self, from: root.appendingPathComponent("connectors.json")) ?? [] }
    func save(_ servers: [MCPServerConfig]) { write(servers, to: root.appendingPathComponent("connectors.json")) }

    func loadSkills() -> [Skill]? { read([Skill].self, from: root.appendingPathComponent("skills.json")) }
    func save(_ skills: [Skill]) { write(skills, to: root.appendingPathComponent("skills.json")) }

    func loadPendingInstalls() -> [PendingInstall] {
        read([PendingInstall].self, from: root.appendingPathComponent("pending.json")) ?? []
    }

    func save(_ pending: [PendingInstall]) { write(pending, to: root.appendingPathComponent("pending.json")) }

    /// API keys live in the Keychain, never in the library file.
    func loadLibrary() -> Library {
        var library = read(Library.self, from: root.appendingPathComponent("library.json")) ?? Library()
        for index in library.endpoints.indices {
            library.endpoints[index].apiKey = Keychain.get("endpoint.\(library.endpoints[index].id.uuidString)") ?? ""
        }
        // A model added by its link was named after its repository, and what it can do was read from
        // its files. One the app has since come to recommend goes by the name it has there, with what
        // the catalog knows it can do; a build the catalog has moved on from gives the name up.
        let device = DeviceProfile.current()
        for index in library.installed.indices {
            let model = library.installed[index]
            library.installed[index].name = ModelCatalog.displayName(for: model.repo, on: device, stored: model.name)
            if let curated = ModelCatalog.model(repo: model.repo) { library.installed[index].capabilities = curated.capabilities }
        }
        return library
    }

    func save(_ library: Library) {
        var stripped = library
        for index in stripped.endpoints.indices {
            Keychain.set(stripped.endpoints[index].apiKey, for: "endpoint.\(stripped.endpoints[index].id.uuidString)")
            stripped.endpoints[index].apiKey = ""
        }
        write(stripped, to: root.appendingPathComponent("library.json"))
    }
}

enum Keychain {
    private static let service = AppIdentity.bundleID

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: key, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

/// What this build of the app is called by the system. The bundle ID is set
/// in Config (each person who builds the app signs it under their own), so
/// nothing here spells it out.
enum AppIdentity {
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.jflick.resident"
}
