// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "e05",
  platforms: [
    .macOS(.v26)
  ],
  dependencies: [
    // In-app updates. Ships as a prebuilt XCFramework, so this pulls a
    // binary rather than sources — pinned in Package.resolved.
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5")
  ],
  targets: [
    .executableTarget(
      name: "e05",
      dependencies: ["E05Lib"],
      path: "Sources/App",
      linkerSettings: [
        // Sparkle links as @rpath/Sparkle.framework/... and SwiftPM emits
        // only @loader_path, which points at Contents/MacOS once the
        // binary is inside a bundle — where the framework is not. Add the
        // bundle's Frameworks dir so the loader finds it there; the
        // SwiftPM-supplied @loader_path stays too, which is what keeps a
        // plain `swift build` binary resolving against .build.
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
      ]
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
      dependencies: [
        "GhosttyKit",
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      path: "Sources/Lib",
      resources: [
        // `.copy` instead of `.process` because the JS runtime
        // is eval'd verbatim inside a WKUserScript — any SPM
        // processing (future image optimisation if a non-text
        // asset lands in this directory, for instance) would
        // be destructive for the content script.
        .copy("Browser/Resources/cosmetic-runtime.js"),
        .copy("Browser/Resources/scriptlets.js"),
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
