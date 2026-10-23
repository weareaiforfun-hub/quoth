// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Quoth",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Quoth", targets: ["Quoth"]),
        .executable(name: "quoth-eval", targets: ["quoth-eval"]),
        .executable(name: "quoth-mcp", targets: ["quoth-mcp"]),
    ],
    dependencies: [
        // Automatic updates (MIT). Pinned: build-app.sh embeds and re-signs it; release.sh uses the
        // same version's tools.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(
            name: "QuothCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Quoth",
            dependencies: ["QuothCore", .product(name: "Sparkle", package: "Sparkle")],
            exclude: ["Resources"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("AVFoundation"), .linkedFramework("CoreAudio")]
        ),
        .executableTarget(
            name: "quoth-eval",
            dependencies: ["QuothCore"]
        ),
        .executableTarget(
            name: "quoth-mcp",
            dependencies: ["QuothCore"]
        ),
        .testTarget(
            name: "QuothCoreTests",
            dependencies: ["QuothCore"]
        ),
    ]
)
