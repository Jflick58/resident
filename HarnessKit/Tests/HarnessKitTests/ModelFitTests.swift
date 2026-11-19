import Foundation
import Testing

@testable import HarnessKit

@Suite struct ModelFitTests {
    static let gigabyte: Int64 = 1 << 30
    static let phone = DeviceProfile(memoryBudgetBytes: 6 * gigabyte, freeDiskBytes: 40 * gigabyte)

    static func mlxRepo(weights: Double, repo: String = "mlx-community/Test-4bit", extra: [String: JSONValue] = [:]) -> HubModelInfo {
        var config: [String: JSONValue] = [
            "model_type": "qwen3", "num_hidden_layers": 36, "num_key_value_heads": 8, "head_dim": 128,
            "max_position_embeddings": 40960, "quantization": ["bits": 4, "group_size": 64],
        ]
        config.merge(extra) { _, new in new }
        return HubModelInfo(
            repo: repo,
            files: [
                .init(path: "model.safetensors", size: Int64(weights * Double(gigabyte))),
                .init(path: "config.json", size: 2000), .init(path: "tokenizer.json", size: 11 << 20),
            ],
            tags: ["mlx"], config: .object(config), chatTemplate: "{% if tools %}<tool_call>{% endif %}{{ enable_thinking }}")
    }

    @Test func parsesRepoIDs() {
        #expect(ModelFit.repoID(from: "mlx-community/Qwen3-4B-4bit") == "mlx-community/Qwen3-4B-4bit")
        #expect(ModelFit.repoID(from: " https://huggingface.co/mlx-community/Qwen3-4B-4bit ") == "mlx-community/Qwen3-4B-4bit")
        #expect(ModelFit.repoID(from: "https://huggingface.co/mlx-community/Qwen3-4B-4bit/tree/main?x=1") == "mlx-community/Qwen3-4B-4bit")
        #expect(ModelFit.repoID(from: "huggingface.co/models/org/name") == "org/name")
        #expect(ModelFit.repoID(from: "hf.co/org/name") == "org/name")
        #expect(ModelFit.repoID(from: "https://example.com/org/name") == nil)
        #expect(ModelFit.repoID(from: "just-a-name") == nil)
        #expect(ModelFit.repoID(from: "") == nil)
    }

    @Test func smallModelRunsWell() {
        let report = ModelFit.evaluate(Self.mlxRepo(weights: 2.1), device: Self.phone)
        #expect(report.verdict == .runsWell)
        #expect(report.contextTokens >= 8192)
        #expect(report.capabilities.tools)
        #expect(report.capabilities.thinking)
        #expect(!report.capabilities.vision)
        #expect(report.canInstall)
    }

    @Test func hybridModelsGetLongContext() {
        // LFM3 1.7B: 24 layers, of which 6 are full attention.
        let types: [JSONValue] = (0..<24).map { $0 % 4 == 2 ? "full_attention" : ($0 % 2 == 0 ? "sliding_attention" : "conv") }
        let hybrid = Self.mlxRepo(
            weights: 0.91,
            extra: [
                "model_type": "lfm3", "num_hidden_layers": 24, "num_key_value_heads": 4, "head_dim": 128,
                "max_position_embeddings": 262144, "layer_types": .array(types),
            ])
        #expect(ModelFit.cacheBytesPerToken(config: hybrid.config) == 12288)
        #expect(ModelFit.evaluate(hybrid, device: Self.phone).contextTokens == 32768)

        // Gemma 4 E2B: 7 full-attention layers, but the last 20 layers share a cache.
        let gemma: [JSONValue] = (0..<35).map { $0 % 5 == 4 ? "full_attention" : "sliding_attention" }
        let shared = Self.mlxRepo(
            weights: 3.3,
            extra: [
                "num_hidden_layers": 35, "num_key_value_heads": 1, "head_dim": 256, "layer_types": .array(gemma),
                "num_kv_shared_layers": 20,
            ])
        #expect(ModelFit.cacheBytesPerToken(config: shared.config) == 3 * 1024)

        // A plain transformer of the same size pays for every layer and stays at 16k or less.
        #expect(ModelFit.evaluate(Self.mlxRepo(weights: 1.0), device: Self.phone).contextTokens == 16384)
    }

    @Test func largeModelIsTightThenWontRun() {
        let tight = ModelFit.evaluate(Self.mlxRepo(weights: 4.3), device: Self.phone)
        #expect(tight.verdict == .tight)
        #expect(tight.contextTokens < 16384)

        let tooBig = ModelFit.evaluate(Self.mlxRepo(weights: 9), device: Self.phone)
        #expect(tooBig.verdict == .wontRun)
        #expect(tooBig.detail.contains("6.0 GB"))
        #expect(!tooBig.canInstall)
    }

    @Test func ggufIsUnsupported() {
        let info = HubModelInfo(repo: "org/model-GGUF", files: [.init(path: "model-q4.gguf", size: 2 << 30)])
        let report = ModelFit.evaluate(info, device: Self.phone)
        #expect(report.verdict == .unsupported)
        #expect(report.detail.contains("GGUF"))
    }

    @Test func originalWeightsAreUnsupported() {
        var info = Self.mlxRepo(weights: 2, repo: "Qwen/Qwen3-4B")
        info.tags = ["transformers"]
        info.config = ["model_type": "qwen3", "num_hidden_layers": 36]
        #expect(ModelFit.evaluate(info, device: Self.phone).headline == "Not converted for MLX")
    }

    @Test func unknownArchitectureIsUnsupported() {
        let report = ModelFit.evaluate(
            Self.mlxRepo(weights: 2, extra: ["model_type": "mystery"]), device: Self.phone,
            supportedArchitectures: ["qwen3", "gemma4"])
        #expect(report.verdict == .unsupported)
        #expect(report.detail.contains("mystery"))
    }

    @Test func oneBitNeedsSpecialRuntime() {
        let report = ModelFit.evaluate(
            Self.mlxRepo(weights: 1.2, extra: ["quantization": ["bits": 1]]), device: Self.phone)
        #expect(report.verdict == .unsupported)
    }

    @Test func notEnoughStorage() {
        let device = DeviceProfile(memoryBudgetBytes: 6 * Self.gigabyte, freeDiskBytes: 1 * Self.gigabyte)
        let report = ModelFit.evaluate(Self.mlxRepo(weights: 2), device: device)
        #expect(report.verdict == .wontRun)
        #expect(report.headline == "Not enough storage")
    }

    @Test func detectsVision() {
        let info = Self.mlxRepo(weights: 2, extra: ["vision_config": ["hidden_size": 768]])
        #expect(ModelFit.capabilities(of: info).vision)
    }

    @Test func cacheEstimateUsesNestedTextConfig() {
        let config: JSONValue = ["text_config": ["num_hidden_layers": 10, "num_key_value_heads": 2, "head_dim": 100]]
        #expect(ModelFit.cacheBytesPerToken(config: config) == 2 * 10 * 2 * 100 * 2)
    }

    @Test func catalogFitsMatchExpectations() {
        // On a 6 GB budget every curated model installs except the 27B.
        let largest = "prism-ml/Ternary-Bonsai-2-27B-mlx-2bit"
        for model in ModelCatalog.models where model.repo != largest {
            let report = model.fit(on: Self.phone)
            #expect(report.canInstall, "\(model.name): \(report.headline)")
        }
        #expect(ModelCatalog.model(repo: largest)?.fit(on: Self.phone).verdict == .wontRun)
        let tablet = DeviceProfile(memoryBudgetBytes: 10 * Self.gigabyte, freeDiskBytes: 40 * Self.gigabyte)
        #expect(ModelCatalog.model(repo: "mlx-community/gemma-4-e4b-it-4bit")?.fit(on: tablet).verdict == .runsWell)
        #expect(ModelCatalog.model(repo: "mlx-community/Qwen3-4B-4bit")?.fit(on: Self.phone).verdict == .runsWell)

        let oldPhone = DeviceProfile(memoryBudgetBytes: 3 * Self.gigabyte, freeDiskBytes: 40 * Self.gigabyte)
        #expect(ModelCatalog.model(repo: "mlx-community/gemma-4-e4b-it-4bit")?.fit(on: oldPhone).verdict == .wontRun)
        #expect(ModelCatalog.model(repo: "mlx-community/Qwen3-1.7B-4bit")?.fit(on: oldPhone).canInstall == true)
    }

    @Test func recommendsOnlyWhatLeavesRoomForAnAgentsPrompt() {
        func names(_ gigabytes: Int64) -> Set<String> {
            let device = DeviceProfile(memoryBudgetBytes: gigabytes * Self.gigabyte, freeDiskBytes: 40 * Self.gigabyte)
            return Set(ModelCatalog.recommended(on: device).map(\.model.name))
        }
        // Gemma 4 E4B fits a 6 GB budget only with 4,000 tokens of context, less than an agent's own prompt can take.
        #expect(ModelCatalog.model(repo: "mlx-community/gemma-4-e4b-it-4bit")?.fit(on: Self.phone).verdict == .tight)
        #expect(!names(6).contains("Gemma 4 E4B"))
        #expect(names(6).isSuperset(of: ["LFM3 1.7B", "LFM3 VL 2B", "Bonsai 2 9B", "Bonsai 2 4B", "Qwen 3.5 4B", "Gemma 4 E2B"]))
        #expect(names(10).contains("Gemma 4 E4B"))
        // The 27B is offered where it has room, and nowhere else.
        #expect(!names(6).contains("Bonsai 2 27B"))
        #expect(!names(10).contains("Bonsai 2 27B"))
        #expect(names(14).contains("Bonsai 2 27B"))
    }

    @Test func catalogCountsOnlyTheLayersWhoseCacheGrows() {
        // What the catalog records gives the estimate the repository's own configuration gives.
        // Qwen 3.5 4B has 32 layers, 8 of them full attention.
        let types: [JSONValue] = (0 ..< 32).map { $0 % 4 == 3 ? "full_attention" : "linear_attention" }
        let config: JSONValue = [
            "text_config": ["num_hidden_layers": 32, "num_key_value_heads": 4, "head_dim": 256, "layer_types": .array(types)]
        ]
        let recorded = ModelCatalog.model(repo: "mlx-community/Qwen3.5-4B-4bit")?.hubInfo.config
        #expect(ModelFit.cacheBytesPerToken(config: recorded) == ModelFit.cacheBytesPerToken(config: config))
    }

    @Test func modelsGoByTheNameTheyAreRecommendedUnder() {
        #expect(ModelCatalog.displayName(for: "prism-ml/Ternary-Bonsai-2-27B-mlx-2bit") == "Bonsai 2 27B")
        #expect(ModelCatalog.displayName(for: "PRISM-ML/ternary-bonsai-2-9b-mlx-2bit") == "Bonsai 2 9B")
        #expect(ModelCatalog.displayName(for: "someone/Their-Model-MLX-4bit") == "Their Model MLX 4bit")
    }
}
