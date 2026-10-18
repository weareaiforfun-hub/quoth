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
    targets: [
        .target(
            name: "QuothCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Quoth",
            dependencies: ["QuothCore"],
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
