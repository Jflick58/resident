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
        // LFM3's text model carries an empty one, and cannot see.
        #expect(!ModelFit.capabilities(of: Self.mlxRepo(weights: 2, extra: ["vision_config": [:]])).vision)
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

    @Test func aModelTooLargeToHoldIsMappedAndSaysItFillsMemory() {
        // A 12 GB phone lets an app hold about 6 GB. The 27B's weights are 8.6 GB.
        let phone = DeviceProfile(memoryBudgetBytes: 6 * Self.gigabyte, freeDiskBytes: 40 * Self.gigabyte, physicalMemoryBytes: 12 * Self.gigabyte)
        let large = ModelCatalog.model(repo: "prism-ml/Ternary-Bonsai-2-27B-mlx-2bit")!
        let report = large.fit(on: phone)
        #expect(report.canInstall && report.fillsMemory && report.verdict == .tight)
        #expect(report.headline == "Will run slowly: it fills this device's memory")
        #expect(report.contextTokens == 32768)
        #expect(ModelCatalog.recommended(on: phone).contains { $0.model.repo == large.repo })
        // What fits the ordinary way is left to: nothing about it says mapped.
        let small = ModelCatalog.model(repo: "prism-ml/Ternary-Bonsai-2-9B-mlx-2bit")!.fit(on: phone)
        #expect(small.verdict == .runsWell && !small.fillsMemory)
        // The same sums decide how a model is loaded.
        #expect(ModelFit.needsMapping(weightBytes: large.weightBytes, cacheBytesPerToken: 16384, device: phone))
        #expect(!ModelFit.needsMapping(weightBytes: 3_460_000_000, cacheBytesPerToken: 16384, device: phone))
        // Weights over three quarters of the device's memory would wait on storage at every token: too large.
        let smaller = DeviceProfile(memoryBudgetBytes: 4 * Self.gigabyte, freeDiskBytes: 40 * Self.gigabyte, physicalMemoryBytes: 8 * Self.gigabyte)
        #expect(large.fit(on: smaller).verdict == .wontRun)
        #expect(!ModelFit.needsMapping(weightBytes: large.weightBytes, cacheBytesPerToken: 16384, device: smaller))
        // A device whose memory is not known is judged by what an app may hold, as before.
        #expect(large.fit(on: Self.phone).verdict == .wontRun)
    }

    @Test func modelsGoByTheNameTheyAreRecommendedUnder() {
        func name(_ repo: String, stored: String? = nil) -> String { ModelCatalog.displayName(for: repo, on: Self.phone, stored: stored) }
        #expect(name("prism-ml/Ternary-Bonsai-2-27B-mlx-2bit", stored: "Ternary Bonsai 2 27B mlx 2bit") == "Bonsai 2 27B")
        #expect(name("PRISM-ML/ternary-bonsai-2-9b-mlx-2bit") == "Bonsai 2 9B")
        #expect(name("someone/Their-Model-MLX-4bit") == "Their Model MLX 4bit")
        // A name the user's model was stored under is kept.
        #expect(name("someone/Their-Model-MLX-4bit", stored: "Mine") == "Mine")
        // Of one author's three coder fine-tunes only one is recommended: the others keep their repository's name.
        #expect(name("AJ-Gonzalez/coder-lfm3-1.7b-k3.1-pro") == "LFM3 Coder 1.7B")
        #expect(name("AJ-Gonzalez/coder-lfm3-1.7b-qwen4-max", stored: "coder lfm3 1.7b qwen4 max") == "coder lfm3 1.7b qwen4 max")
    }

    @Test func recommendsTheBuildThatLeavesTheConversationTheMostRoom() {
        func device(_ megabytes: Int64) -> DeviceProfile {
            DeviceProfile(memoryBudgetBytes: megabytes << 20, freeDiskBytes: 40 * Self.gigabyte)
        }
        func lfm3(_ megabytes: Int64) -> (repo: String, context: Int)? {
            ModelCatalog.recommended(on: device(megabytes)).first { $0.model.name == "LFM3 1.7B" }.map { ($0.model.repo, $0.report.contextTokens) }
        }
        let better = "LiquidAI/LFM3-1.7B-MLX-6bit"
        let lighter = "LiquidAI/LFM3-1.7B-MLX-4bit"
        // With room for both at full length, the build closer to the model as trained.
        #expect(lfm3(6144)?.repo == better)
        #expect(lfm3(3072)?.repo == better)
        // Where the larger build would shorten the conversation, or not fit at all, the lighter one.
        #expect(lfm3(2560)! == (lighter, 32768))
        #expect(lfm3(2048)?.repo == lighter)
        // One line in the list either way, and both builds are known to the catalog.
        #expect(ModelCatalog.recommended(on: device(2048)).filter { $0.model.name == "LFM3 1.7B" }.count == 1)
        #expect(ModelCatalog.model(repo: lighter)?.capabilities == ModelCatalog.model(repo: better)?.capabilities)
        #expect(ModelCatalog.model(repo: lighter)?.weightBytes == 970_000_000)
    }

    @Test func twoBuildsOfOneModelNeverShareAName() {
        let better = "LiquidAI/LFM3-1.7B-MLX-6bit"
        let lighter = "LiquidAI/LFM3-1.7B-MLX-4bit"
        // The build offered on a device has the model's name there. The other, added by its link or
        // installed back when it was the one recommended, is named from its repository.
        #expect(ModelCatalog.displayName(for: better, on: Self.phone, stored: "LFM3 1.7B MLX 6bit") == "LFM3 1.7B")
        #expect(ModelCatalog.displayName(for: lighter, on: Self.phone, stored: "LFM3 1.7B") == "LFM3 1.7B MLX 4bit")
        let small = DeviceProfile(memoryBudgetBytes: 2 * Self.gigabyte, freeDiskBytes: 40 * Self.gigabyte)
        #expect(ModelCatalog.displayName(for: lighter, on: small, stored: "LFM3 1.7B") == "LFM3 1.7B")
        #expect(ModelCatalog.displayName(for: better, on: small) == "LFM3 1.7B MLX 6bit")
        // A build the catalog has dropped altogether gives up a name the catalog still uses.
        #expect(ModelCatalog.displayName(for: "LiquidAI/LFM3-1.7B-MLX-5bit", on: Self.phone, stored: "LFM3 1.7B") == "LFM3 1.7B MLX 5bit")
    }
}
