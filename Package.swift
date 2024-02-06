// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GodotVision",
    platforms: [
        .macOS(.v13),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "GodotVision", targets: ["GodotVision"])
    ],
    dependencies: [
        .package(url: "https://github.com/multijam/SwiftGodotKit", revision: "e7536873ac6ce5d36942cb7f49c2a10de53f831d"),
    ],
    targets: [
        .target(
            name: "GodotVision",
            dependencies: ["SwiftGodotKit"]
            // sources are implicitly in 'Sources' directory.
        )
    ]
)
