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
    public var layers: Int
    public var keyValueHeads: Int
    public var headDimension: Int
    public var architecture: String
    public var capabilities: ModelCapabilities

    public var id: String { repo }

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
        CatalogModel(
            repo: "LiquidAI/LFM3-1.7B-MLX-4bit", name: "LFM3 1.7B", maker: "Liquid AI",
            blurb: "Small, fast, and the most dependable with tools in our tests. Text only.",
            weightBytes: gigabytes(0.97), layers: 6, keyValueHeads: 4, headDimension: 128,
            architecture: "lfm3",
            capabilities: .init(vision: false, tools: true, thinking: true)),
        // The same language model with an image encoder in front.
        CatalogModel(
            repo: "LiquidAI/LFM3-VL-2B-MLX-4bit", name: "LFM3 VL 2B", maker: "Liquid AI",
            blurb: "LFM3 with sight: reads photos, screenshots and documents.",
            weightBytes: gigabytes(1.59), layers: 6, keyValueHeads: 4, headDimension: 128,
            architecture: "lfm3_vl",
            capabilities: .init(vision: true, tools: true, thinking: true)),
        // PrismML's ternary models: Qwen 3.5 with each weight held in two bits, so
        // a model takes about a third of the room of its 4-bit build.
        CatalogModel(
            repo: "prism-ml/Ternary-Bonsai-2-9B-mlx-2bit", name: "Bonsai 2 9B", maker: "PrismML",
            blurb: "A 9B model in the space of a 4B. The most capable here; sees images.",
            weightBytes: gigabytes(3.60), layers: 8, keyValueHeads: 4, headDimension: 256,
            architecture: "prism_hadamard_qwen35",
            capabilities: .init(vision: true, tools: true, thinking: true)),
        CatalogModel(
            repo: "prism-ml/Ternary-Bonsai-2-4B-mlx-2bit", name: "Bonsai 2 4B", maker: "PrismML",
            blurb: "A 4B model in under 2 GB. Sees images.",
            weightBytes: gigabytes(1.94), layers: 8, keyValueHeads: 4, headDimension: 256,
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
            weightBytes: gigabytes(3.03), layers: 32, keyValueHeads: 4, headDimension: 256,
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
            weightBytes: gigabytes(3.55), layers: 35, keyValueHeads: 1, headDimension: 256,
            architecture: "gemma4",
            capabilities: .init(vision: true, tools: true, thinking: true)),
        CatalogModel(
            repo: "mlx-community/Qwen3.5-2B-4bit", name: "Qwen 3.5 2B", maker: "Alibaba",
            blurb: "Fast and light, still handles tools and images.",
            weightBytes: gigabytes(1.72), layers: 24, keyValueHeads: 2, headDimension: 256,
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
            weightBytes: gigabytes(5.15), layers: 42, keyValueHeads: 2, headDimension: 256,
            architecture: "gemma4",
            capabilities: .init(vision: true, tools: true, thinking: true)),
    ]

    public static func model(repo: String) -> CatalogModel? {
        models.first { $0.repo.caseInsensitiveCompare(repo) == .orderedSame }
    }
}
