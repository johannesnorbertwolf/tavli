// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TavliEngine",
    platforms: [.macOS(.v14), .iOS(.v16)],
    products: [
        .library(name: "TavliEngine", targets: ["TavliEngine"]),
    ],
    targets: [
        .target(
            name: "TavliEngine",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TavliEngineTests",
            dependencies: ["TavliEngine"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
