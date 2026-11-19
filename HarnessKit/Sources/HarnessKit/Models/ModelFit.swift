import Foundation

#if canImport(os)
    import os
#endif

/// What we know about a Hugging Face repository before downloading any weights.
public struct HubModelInfo: Sendable {
    public struct File: Hashable, Sendable {
        public var path: String
        public var size: Int64
        public init(path: String, size: Int64) {
            self.path = path
            self.size = size
        }
    }

    public var repo: String
    public var files: [File]
    public var tags: [String]
    public var libraryName: String?
    public var isGated: Bool
    /// Contents of `config.json`.
    public var config: JSONValue?
    public var chatTemplate: String?

    public init(
        repo: String, files: [File], tags: [String] = [], libraryName: String? = nil,
        isGated: Bool = false, config: JSONValue? = nil, chatTemplate: String? = nil
    ) {
        self.repo = repo
        self.files = files
        self.tags = tags
        self.libraryName = libraryName
        self.isGated = isGated
        self.config = config
        self.chatTemplate = chatTemplate
    }
}

/// The limits of the device a model would run on.
public struct DeviceProfile: Sendable {
    /// Memory an app can use before the system ends it.
    public var memoryBudgetBytes: Int64
    public var freeDiskBytes: Int64
    /// All the memory the device has, or 0 when that is not known. A model too large for
    /// `memoryBudgetBytes` can still run with its weights read from their file as they are needed,
    /// which the system does not count against the app, as long as they fit in this.
    public var physicalMemoryBytes: Int64

    public init(memoryBudgetBytes: Int64, freeDiskBytes: Int64, physicalMemoryBytes: Int64 = 0) {
        self.memoryBudgetBytes = memoryBudgetBytes
        self.freeDiskBytes = freeDiskBytes
        self.physicalMemoryBytes = physicalMemoryBytes
    }

    public static func current() -> DeviceProfile {
        DeviceProfile(
            memoryBudgetBytes: currentMemoryBudget(), freeDiskBytes: currentFreeDisk(),
            physicalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory))
    }

    static func currentMemoryBudget() -> Int64 {
        let physical = Int64(ProcessInfo.processInfo.physicalMemory)
        #if os(iOS) || os(visionOS)
            #if targetEnvironment(simulator)
                // The simulator reports the Mac's memory. Model a current Pro iPhone instead.
                return 6 << 30
            #else
                // What the system will still grant this process, plus what it already uses.
                let available = Int64(os_proc_available_memory())
                if available > 0 { return min(physical, available + currentFootprint()) }
                return physical / 2
            #endif
        #else
            return physical * 6 / 10
        #endif
    }

    static func currentFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    static func currentFreeDisk() -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

public enum FitVerdict: String, Codable, Sendable {
    /// Fits with room for a long conversation.
    case runsWell
    /// Fits, with a shorter context.
    case tight
    /// Too big for this device's memory or storage.
    case wontRun
    /// Not a format or architecture the app can load.
    case unsupported
}

public struct ModelCapabilities: Codable, Hashable, Sendable {
    public var vision: Bool
    public var tools: Bool
    public var thinking: Bool

    public init(vision: Bool = false, tools: Bool = false, thinking: Bool = false) {
        self.vision = vision
        self.tools = tools
        self.thinking = thinking
    }
}

public struct FitReport: Sendable {
    public var verdict: FitVerdict
    /// One line the UI can show as is, e.g. "Runs well on this iPhone".
    public var headline: String
    /// The reason, in a sentence.
    public var detail: String
    public var downloadBytes: Int64
    public var weightBytes: Int64
    /// Estimated memory in use at `contextTokens`.
    public var estimatedMemoryBytes: Int64
    /// The context length the app should use for this model on this device.
    public var contextTokens: Int
    public var architecture: String?
    public var quantizationBits: Int?
    public var capabilities: ModelCapabilities
    /// True when the model runs only with its weights read from their file as they are needed: it
    /// is larger than the app may hold, and fills most of the device's memory while it is at work.
    public var fillsMemory = false

    public var canInstall: Bool { verdict == .runsWell || verdict == .tight }
}

public enum ModelFit {
    /// Accepts a repository ID (`org/name`) or any huggingface.co URL that points into one.
    public static func repoID(from input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let range = text.range(of: "huggingface.co/", options: .caseInsensitive) {
            text = String(text[range.upperBound...])
        } else if let range = text.range(of: "hf.co/", options: .caseInsensitive) {
            text = String(text[range.upperBound...])
        } else if text.contains("://") {
            return nil
        }
        if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = String(text[..<cut]) }
        var parts = text.split(separator: "/").map(String.init)
        if parts.first == "models" { parts.removeFirst() }
        guard parts.count >= 2 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let owner = parts[0]
        let name = parts[1]
        guard owner.unicodeScalars.allSatisfy(allowed.contains), name.unicodeScalars.allSatisfy(allowed.contains)
        else { return nil }
        return "\(owner)/\(name)"
    }

    /// Bytes of key-value cache one token of context costs, from the model's dimensions.
    static func cacheBytesPerToken(config: JSONValue?) -> Int64 {
        // Vision-language configs nest the language model's dimensions.
        let text = config?["text_config"] ?? config
        guard var layers = text?["num_hidden_layers"]?.intValue else { return 160_000 }
        // Hybrid models (Qwen 3.5, Gemma 4, LFM3) mix full attention with layers
        // whose state does not grow: convolution, linear attention, or attention
        // over a short sliding window. Only the full-attention layers cost memory
        // per token, and Gemma's last layers reuse an earlier layer's cache.
        if let types = text?["layer_types"]?.arrayValue?.compactMap(\.stringValue), !types.isEmpty {
            let shared = text?["num_kv_shared_layers"]?.intValue ?? 0
            layers = max(1, types.prefix(max(0, types.count - shared)).filter { $0 == "full_attention" }.count)
        }
        let attentionHeads = text?["num_attention_heads"]?.intValue
        let kvHeads = text?["num_key_value_heads"]?.intValue ?? attentionHeads ?? 8
        let headDimension: Int
        if let explicit = text?["head_dim"]?.intValue {
            headDimension = explicit
        } else if let hidden = text?["hidden_size"]?.intValue, let attentionHeads, attentionHeads > 0 {
            headDimension = hidden / attentionHeads
        } else {
            headDimension = 128
        }
        // Keys and values, 16-bit floats.
        return Int64(2 * layers * kvHeads * headDimension * 2)
    }

    /// What the app is charged for a model at a context length. `mapped` is with the weights read from
    /// their file as they are needed, which the system does not count against the app.
    static func estimatedMemory(weightBytes: Int64, cacheBytesPerToken: Int64, contextTokens: Int, mapped: Bool = false) -> Int64 {
        // Weights are held in memory at about their file size. Add the cache for
        // the context, plus working memory for activations and the app itself.
        let overhead = Int64(400 << 20) + weightBytes / 10
        return (mapped ? 0 : weightBytes) + cacheBytesPerToken * Int64(contextTokens) + overhead
    }

    /// True when a model's weights can be mapped on this device: they are not charged to the app,
    /// but they still have to fit in the device's memory beside everything else, or every token
    /// waits on storage. Three quarters of it is the most that has been seen to work: an 8.6 GB
    /// model on a 12 GB iPhone, slowly.
    static func canMap(weightBytes: Int64, on device: DeviceProfile) -> Bool {
        device.physicalMemoryBytes > 0 && weightBytes <= device.physicalMemoryBytes * 3 / 4
    }

    /// True when the model in `directory` has to be loaded with its weights mapped: held the ordinary
    /// way it would not fit in what the app may use, at any context length. Everything smaller loads
    /// the ordinary way. The same sums as `evaluate`, from the model's own files.
    public static func needsMapping(modelDirectory directory: URL, device: DeviceProfile) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let weightBytes = files.filter { $0.pathExtension == "safetensors" && !$0.lastPathComponent.hasPrefix("prompt-cache") }
            .reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let config = (try? Data(contentsOf: directory.appendingPathComponent("config.json"))).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        return needsMapping(weightBytes: weightBytes, cacheBytesPerToken: cacheBytesPerToken(config: config), device: device)
    }

    static func needsMapping(weightBytes: Int64, cacheBytesPerToken: Int64, device: DeviceProfile) -> Bool {
        let least = estimatedMemory(weightBytes: weightBytes, cacheBytesPerToken: cacheBytesPerToken, contextTokens: 2048)
        return least > device.memoryBudgetBytes * 95 / 100 && canMap(weightBytes: weightBytes, on: device)
    }

    public static func capabilities(of info: HubModelInfo) -> ModelCapabilities {
        // An empty one says nothing: LFM3's text model carries `"vision_config": {}` and has no image encoder.
        let hasVisionConfig = !(info.config?["vision_config"]?.objectValue?.isEmpty ?? true)
        let hasPreprocessor = info.files.contains { $0.path == "preprocessor_config.json" }
        let template = info.chatTemplate ?? ""
        return ModelCapabilities(
            vision: hasVisionConfig || hasPreprocessor,
            tools: template.contains("tools") || template.contains("tool_call"),
            thinking: template.contains("enable_thinking") || template.contains("<think>")
                || template.contains("reasoning") || template.contains("thinking"))
    }

    /// Decides whether a model can run on a device, without downloading weights.
    ///
    /// - Parameter supportedArchitectures: the `model_type` values the runtime can
    ///   load. Pass nil to skip that check.
    public static func evaluate(
        _ info: HubModelInfo, device: DeviceProfile, supportedArchitectures: Set<String>? = nil
    ) -> FitReport {
        let weights = info.files.filter { $0.path.hasSuffix(".safetensors") && !$0.path.contains("/") }
        let weightBytes = weights.reduce(Int64(0)) { $0 + $1.size }
        let needed = info.files.filter { file in
            !file.path.contains("/")
                && (file.path.hasSuffix(".safetensors") || file.path.hasSuffix(".json")
                    || file.path.hasSuffix(".jinja") || file.path.hasSuffix(".txt") || file.path.hasSuffix(".model"))
        }
        let downloadBytes = needed.reduce(Int64(0)) { $0 + $1.size }
        let architecture = info.config?["model_type"]?.stringValue
        let quantization = info.config?["quantization"]
        let bits = quantization?["bits"]?.intValue
        let capabilities = capabilities(of: info)

        func report(
            _ verdict: FitVerdict, _ headline: String, _ detail: String, context: Int = 0, memory: Int64 = 0, fillsMemory: Bool = false
        ) -> FitReport {
            FitReport(
                verdict: verdict, headline: headline, detail: detail, downloadBytes: downloadBytes,
                weightBytes: weightBytes, estimatedMemoryBytes: memory, contextTokens: context,
                architecture: architecture, quantizationBits: bits, capabilities: capabilities, fillsMemory: fillsMemory)
        }

        // 1. Format.
        let hasGGUF = info.files.contains { $0.path.lowercased().hasSuffix(".gguf") }
        if weights.isEmpty {
            if hasGGUF {
                return report(
                    .unsupported, "Not an MLX model",
                    "This repository holds GGUF files, which this app can't run. Look for an MLX version, usually under mlx-community.")
            }
            return report(
                .unsupported, "No model weights found",
                "This repository has no safetensors weights at its top level.")
        }
        let looksLikeMLX =
            info.tags.contains("mlx") || info.libraryName == "mlx" || quantization != nil
            || info.repo.lowercased().hasPrefix("mlx-community/") || info.repo.lowercased().contains("mlx")
        if !looksLikeMLX {
            return report(
                .unsupported, "Not converted for MLX",
                "This is the original model, not an MLX conversion. Look for an MLX version, usually under mlx-community.")
        }
        if info.config == nil {
            return report(
                .unsupported, "Missing configuration",
                "The repository has no readable config.json, so the model can't be loaded.")
        }

        // 2. Architecture.
        if let supportedArchitectures, let architecture, !supportedArchitectures.contains(architecture) {
            return report(
                .unsupported, "Architecture not supported yet",
                "This model uses the “\(architecture)” architecture, which the app's runtime can't load yet.")
        }
        if let bits, bits < 2 {
            return report(
                .unsupported, "Needs a 1-bit runtime",
                "1-bit models need inference kernels that aren't in the standard MLX runtime yet.")
        }

        // 4. Storage, checked only for a model that would otherwise run.
        func storageProblem() -> FitReport? {
            guard device.freeDiskBytes > 0, downloadBytes + (500 << 20) > device.freeDiskBytes else { return nil }
            return report(
                .wontRun, "Not enough storage",
                "The download is \(format(downloadBytes)) and this device has \(format(device.freeDiskBytes)) free.")
        }

        // 3. Memory, at decreasing context lengths.
        let perToken = cacheBytesPerToken(config: info.config)
        let declaredLimit =
            (info.config?["text_config"] ?? info.config)?["max_position_embeddings"]?.intValue ?? 32768
        let budget = device.memoryBudgetBytes
        let comfortable = budget * 85 / 100

        for context in [32768, 16384, 8192] where context <= max(declaredLimit, 8192) {
            let memory = estimatedMemory(weightBytes: weightBytes, cacheBytesPerToken: perToken, contextTokens: context)
            if memory <= comfortable {
                if let blocked = storageProblem() { return blocked }
                return report(
                    .runsWell, "Runs well on this device",
                    "Uses about \(format(memory)) of the \(format(budget)) apps can use here.",
                    context: context, memory: memory)
            }
        }
        for context in [8192, 4096, 2048] {
            let memory = estimatedMemory(weightBytes: weightBytes, cacheBytesPerToken: perToken, contextTokens: context)
            if memory <= budget * 95 / 100 {
                if let blocked = storageProblem() { return blocked }
                return report(
                    .tight, "Will run, with a shorter memory",
                    "Uses about \(format(memory)) of the \(format(budget)) apps can use here, so conversations are limited to about \(context / 1000)k tokens.",
                    context: context, memory: memory)
            }
        }
        // Too large to hold the ordinary way. With its weights read from their file as they are needed
        // it can still run, where the device has the memory for them: it loads, and it is slow.
        if canMap(weightBytes: weightBytes, on: device) {
            for context in [32768, 16384, 8192] where context <= max(declaredLimit, 8192) {
                let memory = estimatedMemory(weightBytes: weightBytes, cacheBytesPerToken: perToken, contextTokens: context, mapped: true)
                guard memory <= comfortable else { continue }
                if let blocked = storageProblem() { return blocked }
                return report(
                    .tight, "Will run slowly: it fills this device's memory",
                    "Its weights are \(format(weightBytes)), more than an app here may hold, so they are read from storage as it runs. Short replies work; long ones slow down.",
                    context: context, memory: memory, fillsMemory: true)
            }
        }
        let minimum = estimatedMemory(weightBytes: weightBytes, cacheBytesPerToken: perToken, contextTokens: 2048)
        return report(
            .wontRun, "Too large for this device",
            "Needs about \(format(minimum)) of memory. Apps on this device get about \(format(budget)), which leaves too little headroom.",
            memory: minimum)
    }

    public static func format(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        if gigabytes >= 1 { return String(format: "%.1f GB", gigabytes) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

/// Reads repository metadata from the Hugging Face Hub.
public struct HubMetadataClient: Sendable {
    private let fetcher: any HTTPFetching
    private let token: String?

    public init(fetcher: any HTTPFetching = URLSessionFetcher(), token: String? = nil) {
        self.fetcher = fetcher
        self.token = token
    }

    public func info(repo: String) async throws -> HubModelInfo {
        let api = try await json("https://huggingface.co/api/models/\(repo)?blobs=true", notFound: "No model named \(repo) on Hugging Face.")
        let files = (api["siblings"]?.arrayValue ?? []).compactMap { item -> HubModelInfo.File? in
            guard let path = item["rfilename"]?.stringValue else { return nil }
            return HubModelInfo.File(path: path, size: Int64(item["size"]?.intValue ?? 0))
        }
        let gated: Bool
        switch api["gated"] {
        case .bool(let value)?: gated = value
        case .string?: gated = true
        default: gated = false
        }

        var config: JSONValue?
        if files.contains(where: { $0.path == "config.json" }) {
            config = try? await json("https://huggingface.co/\(repo)/resolve/main/config.json", notFound: "")
        }
        var template = api["config"]?["tokenizer_config"]?["chat_template"]?.stringValue
        if template == nil, files.contains(where: { $0.path == "chat_template.jinja" }) {
            template = try? await text("https://huggingface.co/\(repo)/resolve/main/chat_template.jinja")
        }

        return HubModelInfo(
            repo: api["id"]?.stringValue ?? repo, files: files,
            tags: (api["tags"]?.arrayValue ?? []).compactMap(\.stringValue),
            libraryName: api["library_name"]?.stringValue, isGated: gated, config: config,
            chatTemplate: template)
    }

    private func data(_ address: String) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: address) else { throw ProviderError("Invalid address.") }
        var request = URLRequest(url: url)
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await fetcher.fetch(request)
    }

    private func json(_ address: String, notFound: String) async throws -> JSONValue {
        let (data, response) = try await data(address)
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw ProviderError("This model is private or gated. Accept its terms on Hugging Face and add an access token in Settings.")
        case 404: throw ProviderError(notFound)
        default: throw ProviderError("Hugging Face answered with status \(response.statusCode).")
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func text(_ address: String) async throws -> String {
        let (data, response) = try await data(address)
        guard (200..<300).contains(response.statusCode) else { throw ProviderError("Not found.") }
        return String(decoding: data, as: UTF8.self)
    }
}
