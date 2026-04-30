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
    dependencies: [
        .package(url: "https://github.com/mxcl/Version", from: "2.2.1"),
    ],
    targets: [
        .target(
            name: "AppUpdater",
            dependencies: ["Version"],
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
