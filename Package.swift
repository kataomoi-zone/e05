// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "e05",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "e05",
            dependencies: ["GhosttyKit"],
            path: "Sources",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon"),
            ]
        ),
        .binaryTarget(
            name: "GhosttyKit",
            path: "GhosttyKit.xcframework"
        ),
    ]
)
