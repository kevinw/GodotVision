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
        //.package(path: "../SwiftGodotKit")
        .package(url: "https://github.com/multijam/SwiftGodotKit", revision: "526ae902f84c1604d30680d8198c09fdfa566848"),
    ],
    targets: [
        .target(
            name: "GodotVision",
            /* static build experiment...
            dependencies: ["binary_SwiftGodotKit", "binary_libgodot"],
            */
            dependencies: ["SwiftGodotKit"],
            path: "Sources"
            // sources are implicitly in 'Sources' directory.
        ),

        /*
         static build experiment...
        .binaryTarget (
            name: "binary_SwiftGodotKit",
            path: "../SwiftGodotKit/SwiftGodotKit.xcframework"
        ),
        .binaryTarget(name: "binary_libgodot", path: "../SwiftGodot/libgodot.xcframework")
         */
    ]
)
