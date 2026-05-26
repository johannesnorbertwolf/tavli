// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TavliEngine",
    platforms: [.macOS(.v14), .iOS(.v16)],
    products: [
        .library(name: "TavliEngine", targets: ["TavliEngine"]),
        .library(name: "BoardGeometry", targets: ["BoardGeometry"]),
    ],
    targets: [
        .target(
            name: "TavliEngine",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "BoardGeometry",
            exclude: ["CLAUDE.md"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TavliEngineTests",
            dependencies: ["TavliEngine"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BoardGeometryTests",
            dependencies: ["BoardGeometry"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
