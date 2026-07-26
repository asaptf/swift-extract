// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ReceiptScanner",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .executable(name: "ReceiptScanner", targets: ["ReceiptScanner"])
    ],
    dependencies: [
        .package(
            path: "../..",
            traits: ["MLX"]
        ),
        // SPM trait graph workaround + download progress API for the demo.
        // Pin below 2.31: mlx-swift 0.31.5+ pulls experimentalCGen + CudaBuild plugin
        // that fails Xcode package validation on Apple platforms.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "2.30.6"),
    ],
    targets: [
        .executableTarget(
            name: "ReceiptScanner",
            dependencies: [
                .product(name: "Extract", package: "swift-extract"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "Sources",
            resources: [
                .copy("Resources/Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .define("MLX"),
            ]
        )
    ]
)
