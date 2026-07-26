// swift-tools-version: 6.1
import Foundation
import PackageDescription

// SPM path-package identity is the **directory basename**, not Package.swift `name`.
// Local clones may live in `swift-extraction-lib` while GitHub Actions checks out
// `swift-extract` — resolve the product against whichever parent dir we are in.
let rootPackageIdentity = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // Examples/ReceiptScanner
    .deletingLastPathComponent() // Examples
    .deletingLastPathComponent() // repo root
    .lastPathComponent

// SPM package for `swift build` / CI.
// Full MLX download support is enabled in ReceiptScanner.xcodeproj (package trait
// MLX + MLXLMCommon). Keeping the SPM graph free of mlx-swift keeps CI green and
// avoids the heavy Metal/CUDA native build on GitHub Actions.
//
// To build with MLX via SPM locally, see project.yml / README.

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
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "ReceiptScanner",
            dependencies: [
                .product(name: "Extract", package: rootPackageIdentity)
            ],
            path: "Sources",
            resources: [
                .copy("Resources/Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
