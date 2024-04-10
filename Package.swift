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
        .package(url: "https://github.com/multijam/SwiftGodotKit", revision: "bc653e83b1bde52a03ba90a2ed5e2a3ddb7ba3f5"),
    ],
    targets: [
        .target(
            name: "GodotVision",
            dependencies: ["SwiftGodotKit"]
            // sources are implicitly in 'Sources' directory.
        )
    ]
)
