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
        .package(url: "https://github.com/multijam/SwiftGodotKit", revision: "ddda0bd082b5a597f9851059b5079f5bfcbf30a1"),
    ],
    targets: [
        .target(
            name: "GodotVision",
            dependencies: ["SwiftGodotKit"]
            // sources are implicitly in 'Sources' directory.
        )
    ]
)
