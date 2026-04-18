// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "e05",
    platforms: [
        .macOS(.v26),
    ],
    targets: [
        .executableTarget(
            name: "e05",
            dependencies: ["E05Lib"],
            path: "Sources/App"
        ),
        .target(
            name: "E05Lib",
            dependencies: ["GhosttyKit"],
            path: "Sources/Lib",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon"),
                .linkedFramework("WebKit"),
            ]
        ),
        .testTarget(
            name: "E05Tests",
            dependencies: ["E05Lib", "GhosttyKit"],
            path: "Tests"
        ),
        .binaryTarget(
            name: "GhosttyKit",
            path: "GhosttyKit.xcframework"
        ),
    ]
)
