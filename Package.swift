// swift-tools-version:4.2
import PackageDescription

let package = Package(
    name: "AppUpdater",
    products: [
        .library(name: "AppUpdater", targets: ["AppUpdater"]),
    ],
    dependencies: [
        .package(url: "https://github.com/PromiseKit/Foundation", from: "3.3.0"),
        .package(url: "https://github.com/mxcl/Path.swift", from: "0.16.0"),
        .package(url: "https://github.com/mxcl/Version", from: "1.0.0"),
    ],
    targets: [
        .target(name: "AppUpdater", dependencies: ["PMKFoundation", "Path", "Version"], path: ".", sources: ["AppUpdater.swift"]),
    ],
    swiftLanguageVersions: [.v4_2, .version("5")]
)
