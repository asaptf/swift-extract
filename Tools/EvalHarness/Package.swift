// swift-tools-version: 6.1
import Foundation
import PackageDescription

// SPM path-package identity is the **directory basename**, not Package.swift `name`.
// Local clones may live in `swift-extraction-lib` while GitHub Actions checks out
// `swift-extract` — resolve the product against whichever parent dir we are in.
let rootPackageIdentity = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Tools/EvalHarness
    .deletingLastPathComponent()  // Tools
    .deletingLastPathComponent()  // repo root
    .lastPathComponent

// Separate package so library consumers never pull the harness into their graph.
// Build from this directory only: `swift build` / `swift run extract-eval` here.
// Root `swift build` does not compile this package.
//
// MLX backend: enable the `MLX` trait and prefer `xcodebuild` so Metal shaders
// compile (see README). Default builds use the deterministic mock only.

let package = Package(
    name: "EvalHarness",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "EvalHarness", targets: ["EvalHarness"]),
        .executable(name: "extract-eval", targets: ["extract-eval"]),
    ],
    traits: [
        .trait(
            name: "MLX",
            description: "Enable MLX local model backends for accuracy / A/B runs."
        ),
        .default(enabledTraits: []),
    ],
    dependencies: [
        .package(
            path: "../..",
            traits: [
                .trait(name: "MLX", condition: .when(traits: ["MLX"]))
            ]
        ),
        // AnyLanguageModel is already pulled by Extract; re-declare so the MLX trait
        // can be forwarded when building with `--traits MLX`.
        .package(
            url: "https://github.com/huggingface/AnyLanguageModel.git",
            from: "0.8.0",
            traits: [
                .trait(name: "MLX", condition: .when(traits: ["MLX"]))
            ]
        ),
        // Direct mlx-swift-lm dependency is required when the MLX trait is enabled
        // (SPM trait graph). Add/keep it for MLX builds — see README. Listed with a
        // product dependency gated on the trait so default CI does not link it.
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm",
            from: "2.25.5"
        ),
    ],
    targets: [
        .target(
            name: "EvalHarness",
            dependencies: [
                .product(name: "Extract", package: rootPackageIdentity),
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
                .product(
                    name: "MLXLMCommon",
                    package: "mlx-swift-lm",
                    condition: .when(traits: ["MLX"])
                ),
            ],
            path: "Sources/EvalHarness",
            resources: [
                .copy("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency=complete"),
            ]
        ),
        .executableTarget(
            name: "extract-eval",
            dependencies: ["EvalHarness"],
            path: "Sources/extract-eval",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency=complete"),
            ]
        ),
        .testTarget(
            name: "EvalHarnessTests",
            dependencies: ["EvalHarness"],
            path: "Tests/EvalHarnessTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency=complete"),
            ]
        ),
    ]
)
