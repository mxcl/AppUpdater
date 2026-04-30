// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppUpdater",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .library(name: "AppUpdater", targets: ["AppUpdater"]),
    ],
    targets: [
        .target(
            name: "AppUpdater",
            path: ".",
            exclude: ["LICENSE.md", "README.md", "Tests"],
            sources: ["AppUpdater.swift"]
        ),
        .testTarget(
            name: "AppUpdaterTests",
            dependencies: ["AppUpdater"],
            path: "Tests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
