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
        .package(url: "https://github.com/multijam/SwiftGodotKit", revision: "d488f131babbe9ea97d2f930d80ab8bb652a983b"),
    ],
    targets: [
        .target(
            name: "GodotVision",
            dependencies: ["SwiftGodotKit"]
            // sources are implicitly in 'Sources' directory.
        )
    ]
)
