import Foundation

/// A model the app recommends. Sizes and dimensions are recorded here so the
/// list and its fit badges work offline; they were read from each repository's
/// file list and config.json.
public struct CatalogModel: Hashable, Sendable, Identifiable {
    public var repo: String
    public var name: String
    public var maker: String
    public var blurb: String
    public var weightBytes: Int64
    /// The layers whose memory grows with the conversation: the full-attention ones, less any that
    /// share another's. It is what `ModelFit` counts from the repository's own configuration, so a
    /// model gets the same verdict here as when it is added by link.
    public var layers: Int
    public var keyValueHeads: Int
    public var headDimension: Int
    public var architecture: String
    public var capabilities: ModelCapabilities
    /// The same weights rounded to fewer bits: smaller, and further from the model as trained. It is
    /// recommended in this build's place on a device where this one would leave less room for the conversation.
    public var lighter: Build?

    /// Another build of a model: where it is and how large its weights are. Everything else is the model's.
    public struct Build: Hashable, Sendable {
        public var repo: String
        public var weightBytes: Int64
    }

    public var id: String { repo }

    /// The lighter build as a model of its own, when there is one.
    public var lighterModel: CatalogModel? {
        guard let lighter else { return nil }
        var model = self
        model.repo = lighter.repo
        model.weightBytes = lighter.weightBytes
        model.lighter = nil
        return model
    }

    /// The build to offer on `device`, with how it fits: the one that leaves the conversation the most
    /// room, and this one when they leave the same. Better rounding is worth memory but not context:
    /// an agent's prompt and a few tool results fill a short one.
    public func build(on device: DeviceProfile) -> (model: CatalogModel, report: FitReport) {
        let own = (model: self, report: fit(on: device))
        guard let lighterModel else { return own }
        let other = (model: lighterModel, report: lighterModel.fit(on: device))
        func room(_ report: FitReport) -> Int { report.canInstall ? report.contextTokens : 0 }
        return room(other.report) > room(own.report) ? other : own
    }

    /// The same shape the Hub lookup produces, so one fit check serves both paths.
    public var hubInfo: HubModelInfo {
        HubModelInfo(
            repo: repo,
            files: [.init(path: "model.safetensors", size: weightBytes), .init(path: "tokenizer.json", size: 12 << 20)],
            tags: ["mlx"], libraryName: "mlx",
            config: [
                "model_type": .string(architecture),
                "num_hidden_layers": .int(layers),
                "num_key_value_heads": .int(keyValueHeads),
                "head_dim": .int(headDimension),
                "max_position_embeddings": 32768,
                "quantization": ["bits": 4, "group_size": 64],
            ],
            chatTemplate: nil)
    }

    public func fit(on device: DeviceProfile) -> FitReport {
        var report = ModelFit.evaluate(hubInfo, device: device)
        report.capabilities = capabilities
        return report
    }
}

public enum ModelCatalog {
    private static func gigabytes(_ value: Double) -> Int64 { Int64(value * 1_000_000_000) }

    public static let models: [CatalogModel] = [
        // Only 6 of its 24 layers are full attention; the rest keep no per-token state.
        // The 6-bit build: given the same prompts it picks the same next token as the weights as trained
        // 97.3% of the time, where the 4-bit build does 89.5% (spike-results/fidelity-lfm3.txt), for
        // 0.44 GB more. The 4-bit build is kept for devices the difference would cost context on.
        CatalogModel(
            repo: "LiquidAI/LFM3-1.7B-MLX-6bit", name: "LFM3 1.7B", maker: "Liquid AI",
            blurb: "Small, fast, and the most dependable with tools in our tests. Text only.",
            weightBytes: gigabytes(1.41), layers: 6, keyValueHeads: 4, headDimension: 128,
            architecture: "lfm3",
            capabilities: .init(vision: false, tools: true, thinking: true),
            lighter: .init(repo: "LiquidAI/LFM3-1.7B-MLX-4bit", weightBytes: gigabytes(0.97))),
        // The same language model with an image encoder in front.
        CatalogModel(
            repo: "LiquidAI/LFM3-VL-2B-MLX-4bit", name: "LFM3 VL 2B", maker: "Liquid AI",
            blurb: "LFM3 with sight: reads photos, screenshots and documents.",
            weightBytes: gigabytes(1.59), layers: 6, keyValueHeads: 4, headDimension: 128,
            architecture: "lfm3_vl",
            capabilities: .init(vision: true, tools: true, thinking: true)),
        // A community fine-tune of LFM3 on a larger model's worked answers to code questions. Its author
        // publishes three, each taught by a different model. This is the best liked, and it passed the
        // 16 file and pull request cases it was given. The one taught by Qwen 4 Max did no better than
        // stock LFM3 in the suite (62 of 70 cases against 66).
        CatalogModel(
            repo: "AJ-Gonzalez/coder-lfm3-1.7b-k3.1-pro", name: "LFM3 Coder 1.7B", maker: "AJ Gonzalez",
            blurb: "LFM3 tuned for code by a community author. Thinks a problem through before it writes. Text only.",
            weightBytes: gigabytes(0.97), layers: 6, keyValueHeads: 4, headDimension: 128,
            architecture: "lfm3",
            capabilities: .init(vision: false, tools: true, thinking: true)),
        // PrismML's ternary models: Qwen retrained so that each weight is one of three values, held in
        // two bits. Nobody else publishes a build of them the app could load, so the maker's is the one.
        // Listed only where the fit check lets it through. On a 12 GB phone that takes mapped weights,
        // and it reads 6.8 GB of them for every token, which is all the room such a phone has.
        CatalogModel(
            repo: "prism-ml/Ternary-Bonsai-2-27B-mlx-2bit", name: "Bonsai 2 27B", maker: "PrismML",
            blurb: "The most capable here, and the slowest: it fills a 12 GB iPhone, so long replies drag. Sees images.",
            weightBytes: gigabytes(8.60), layers: 16, keyValueHeads: 4, headDimension: 256,
            architecture: "prism_hadamard_qwen35",
            capabilities: .init(vision: true, tools: true, thinking: true)),
        CatalogModel(
            repo: "prism-ml/Ternary-Bonsai-2-9B-mlx-2bit", name: "Bonsai 2 9B", maker: "PrismML",
            blurb: "A 9B model in the space of a 4B. Capable and still quick; sees images.",
            weightBytes: gigabytes(3.46), layers: 8, keyValueHeads: 4, headDimension: 256,
            architecture: "prism_hadamard_qwen35",
            capabilities: .init(vision: true, tools: true, thinking: true)),
        CatalogModel(
            repo: "prism-ml/Ternary-Bonsai-2-4B-mlx-2bit", name: "Bonsai 2 4B", maker: "PrismML",
            blurb: "A 4B model in under 2 GB. Sees images.",
            weightBytes: gigabytes(1.87), layers: 8, keyValueHeads: 4, headDimension: 256,
            architecture: "prism_hadamard_qwen35",
            capabilities: .init(vision: true, tools: true, thinking: true)),
        CatalogModel(
            repo: "prism-ml/Ternary-Bonsai-2-2B-mlx-2bit", name: "Bonsai 2 2B", maker: "PrismML",
            blurb: "The smallest Bonsai. Sees images.",
            weightBytes: gigabytes(1.20), layers: 6, keyValueHeads: 2, headDimension: 256,
            architecture: "prism_hadamard_qwen35",
            capabilities: .init(vision: true, tools: true, thinking: true)),
        CatalogModel(
            repo: "mlx-community/Qwen3.5-4B-4bit", name: "Qwen 3.5 4B", maker: "Alibaba",
            blurb: "Best all-rounder. Strong at tools, sees images.",
            weightBytes: gigabytes(3.03), layers: 8, keyValueHeads: 4, headDimension: 256,
            architecture: "qwen3_5",
            capabilities: .init(vision: true, tools: true, thinking: true)),
        CatalogModel(
            repo: "mlx-community/Qwen3-4B-4bit", name: "Qwen 3 4B", maker: "Alibaba",
            blurb: "Reliable tool use and reasoning. Text only.",
            weightBytes: gigabytes(2.26), layers: 36, keyValueHeads: 8, headDimension: 128,
            architecture: "qwen3",
            capabilities: .init(vision: false, tools: true, thinking: true)),
        CatalogModel(
            repo: "mlx-community/gemma-4-e2b-it-4bit", name: "Gemma 4 E2B", maker: "Google",
            blurb: "Natural writing and good vision in a small footprint.",
            weightBytes: gigabytes(3.55), layers: 3, keyValueHeads: 1, headDimension: 256,
            architecture: "gemma4",
            capabilities: .init(vision: true, tools: true, thinking: true)),
        CatalogModel(
            repo: "mlx-community/Qwen3.5-2B-4bit", name: "Qwen 3.5 2B", maker: "Alibaba",
            blurb: "Fast and light, still handles tools and images.",
            weightBytes: gigabytes(1.72), layers: 6, keyValueHeads: 2, headDimension: 256,
            architecture: "qwen3_5",
            capabilities: .init(vision: true, tools: true, thinking: true)),
        CatalogModel(
            repo: "mlx-community/Qwen3-1.7B-4bit", name: "Qwen 3 1.7B", maker: "Alibaba",
            blurb: "Smallest useful model. For older devices and quick answers.",
            weightBytes: gigabytes(0.97), layers: 28, keyValueHeads: 8, headDimension: 128,
            architecture: "qwen3",
            capabilities: .init(vision: false, tools: true, thinking: true)),
        CatalogModel(
            repo: "mlx-community/gemma-4-e4b-it-4bit", name: "Gemma 4 E4B", maker: "Google",
            blurb: "Google's strongest on-device model. Needs a recent Pro device.",
            weightBytes: gigabytes(5.15), layers: 4, keyValueHeads: 2, headDimension: 256,
            architecture: "gemma4",
            capabilities: .init(vision: true, tools: true, thinking: true)),
    ]

    /// The curated model at this repository, in whichever of its builds that is.
    public static func model(repo: String) -> CatalogModel? {
        (models + models.compactMap(\.lighterModel)).first { $0.repo.caseInsensitiveCompare(repo) == .orderedSame }
    }

    /// The least context a model must be left with to be recommended: an agent's instructions and
    /// tools take a few thousand tokens before the conversation starts.
    public static let leastContext = 8192

    /// The curated models worth offering on `device`, each in the build that suits it: those that fit
    /// with room for an agent's prompt. A model that only runs by filling the device's memory comes
    /// after the ones that run well, whatever its place in the list: it is offered, not suggested.
    public static func recommended(on device: DeviceProfile) -> [(model: CatalogModel, report: FitReport)] {
        let fitting = models.map { $0.build(on: device) }.filter { $0.report.canInstall && $0.report.contextTokens >= leastContext }
        return fitting.filter { !$0.report.fillsMemory } + fitting.filter { $0.report.fillsMemory }
    }

    /// A repository's own name with the dashes read as spaces: what a model added by its link is called.
    static func linkName(_ repo: String) -> String {
        (repo.split(separator: "/").last.map(String.init) ?? repo).replacingOccurrences(of: "-", with: " ")
    }

    /// The name a model goes by on `device`. The build the app would offer there has the name it is
    /// recommended under. Another build of the same model is named from its link, as is a model that
    /// was `stored` under a name the catalog has since given to something else, so that no two models
    /// in the list share a name. Anything else keeps the name it was stored under.
    public static func displayName(for repo: String, on device: DeviceProfile, stored: String? = nil) -> String {
        if let entry = models.first(where: { $0.repo.caseInsensitiveCompare(repo) == .orderedSame || $0.lighter?.repo.caseInsensitiveCompare(repo) == .orderedSame }) {
            let offered = entry.build(on: device).model.repo
            return offered.caseInsensitiveCompare(repo) == .orderedSame ? entry.name : linkName(repo)
        }
        guard let stored, !models.contains(where: { $0.name == stored }) else { return linkName(repo) }
        return stored
    }
}
