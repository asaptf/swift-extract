// swift-tools-version: 6.1
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "swift-extract",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "Extract",
            targets: ["Extract"]
        ),
        .executable(
            name: "extract-cli",
            targets: ["ExtractCLI"]
        ),
    ],
    traits: [
        .trait(
            name: "MLX",
            description: "Enable MLX local model backends via AnyLanguageModel."
        ),
        .trait(
            name: "CoreML",
            description: "Enable Core ML model backends via AnyLanguageModel."
        ),
        .trait(
            name: "Llama",
            description: "Enable llama.cpp (GGUF) backends via AnyLanguageModel."
        ),
        .default(enabledTraits: []),
    ],
    dependencies: [
        .package(
            url: "https://github.com/huggingface/AnyLanguageModel.git",
            from: "0.8.0",
            traits: [
                .trait(name: "MLX", condition: .when(traits: ["MLX"])),
                .trait(name: "CoreML", condition: .when(traits: ["CoreML"])),
                .trait(name: "Llama", condition: .when(traits: ["Llama"])),
            ]
        ),
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "600.0.0"),
    ],
    targets: [
        .macro(
            name: "ExtractMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "Extract",
            dependencies: [
                "ExtractMacros",
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency=complete"),
            ]
        ),
        .executableTarget(
            name: "ExtractCLI",
            dependencies: ["Extract"],
            path: "Sources/ExtractCLI",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency=complete"),
            ]
        ),
        .testTarget(
            name: "ExtractTests",
            dependencies: ["Extract"],
            path: "Tests/ExtractTests",
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency=complete"),
            ]
        ),
        .testTarget(
            name: "ExtractMacrosTests",
            dependencies: [
                "ExtractMacros",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            path: "Tests/ExtractMacrosTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
