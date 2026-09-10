// swift-tools-version: 6.0
// Dubplate — shared modules for the macOS and iOS applications.
//
// The manifest lives at the repository root so that the folder layout described in
// Documentation/ARCHITECTURE.md is the literal layout on disk: module sources under
// Packages/, test bundles under Tests/. The Xcode project (Apps/Dubplate.xcodeproj)
// consumes this package as a local package dependency.

import PackageDescription

let package = Package(
    name: "Dubplate",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(name: "DubplateCore", targets: ["DubplateCore"]),
        .library(name: "DubplateAudio", targets: ["DubplateAudio"]),
        .library(name: "DubplateSync", targets: ["DubplateSync"]),
        .library(name: "DubplateUI", targets: ["DubplateUI"])
    ],
    targets: [
        .target(
            name: "DubplateCore",
            path: "Packages/DubplateCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "DubplateAudio",
            dependencies: ["DubplateCore"],
            path: "Packages/DubplateAudio",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "DubplateSync",
            dependencies: ["DubplateCore"],
            path: "Packages/DubplateSync",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "DubplateUI",
            dependencies: ["DubplateCore", "DubplateAudio", "DubplateSync"],
            path: "Packages/DubplateUI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["DubplateCore"],
            path: "Tests/CoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AudioTests",
            dependencies: ["DubplateCore", "DubplateAudio"],
            path: "Tests/AudioTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SyncTests",
            dependencies: ["DubplateCore", "DubplateSync"],
            path: "Tests/SyncTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
