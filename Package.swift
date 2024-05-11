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
        .package(url: "https://github.com/multijam/SwiftGodotKit", revision: "b705ab685f21744b0c61015e72809e6ac19ffb80"),
    ],
    targets: [
        .target(
            name: "GodotVision",
            dependencies: ["SwiftGodotKit"]
            // sources are implicitly in 'Sources' directory.
        )
    ]
)
