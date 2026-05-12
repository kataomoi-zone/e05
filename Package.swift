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
        // CLI bundled into Contents/Resources/bin/e05 by build_app.sh
        // (renamed from `e05cli` at copy time so PATH-injected callers
        // get the short, brand-correct name).
        .executableTarget(
            name: "e05cli",
            path: "Sources/CLI"
        ),
        .target(
            name: "E05Lib",
            dependencies: ["GhosttyKit"],
            path: "Sources/Lib",
            resources: [
                // `.copy` instead of `.process` because the JS runtime
                // is eval'd verbatim inside a WKUserScript — any SPM
                // processing (future image optimisation if a non-text
                // asset lands in this directory, for instance) would
                // be destructive for the content script.
                .copy("Browser/Resources/cosmetic-runtime.js"),
            ],
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
