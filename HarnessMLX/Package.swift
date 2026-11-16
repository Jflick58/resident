// swift-tools-version: 6.2
import PackageDescription

// On-device inference for the harness, on top of MLX Swift LM. Kept apart from
// HarnessKit so the core builds and tests without the MLX toolchain.
let package = Package(
    name: "HarnessMLX",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "HarnessMLX", targets: ["HarnessMLX"]),
        .executable(name: "harness-spike", targets: ["harness-spike"]),
    ],
    dependencies: [
        .package(path: "../HarnessKit"),
        // Pinned to a commit on main: the session, reasoning and guided-generation APIs
        // used here are newer than the latest tag (3.32.3). Move to a tag once one includes them.
        // The FoundationModels bridge is not used; turning its trait off skips building it.
        // A copy of the library with two open pull requests merged in (LFM3-VL and
        // Bonsai 2). See Vendor/README.md.
        .package(path: "../Vendor/mlx-swift-lm"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.33.0")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "HarnessMLX",
            dependencies: [
                "HarnessKit",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "harness-spike",
            dependencies: ["HarnessMLX", "HarnessKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
