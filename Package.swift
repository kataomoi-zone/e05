// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "e05",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "e05",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ],
            path: "Sources"
        ),
    ]
)
