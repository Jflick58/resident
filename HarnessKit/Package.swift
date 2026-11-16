// swift-tools-version: 6.0
import PackageDescription

// The harness core: agent loop, tools, presets, remote provider and the model
// fit check. No MLX dependency, so it builds and tests in seconds on a Mac.
let package = Package(
    name: "HarnessKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "HarnessKit", targets: ["HarnessKit"])
    ],
    targets: [
        .target(
            name: "HarnessKit",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "harness-mcp",
            dependencies: ["HarnessKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "HarnessKitTests",
            dependencies: ["HarnessKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
