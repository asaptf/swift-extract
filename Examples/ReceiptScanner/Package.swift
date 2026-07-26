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
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "ReceiptScanner",
            dependencies: [
                .product(name: "Extract", package: "swift-extraction-lib")
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
