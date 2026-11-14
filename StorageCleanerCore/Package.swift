// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "StorageCleanerCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "StorageCleanerCore", targets: ["StorageCleanerCore"]),
    ],
    targets: [
        .target(
            name: "StorageCleanerCore",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "StorageCleanerCoreTests",
            dependencies: ["StorageCleanerCore"]
        ),
    ]
)
