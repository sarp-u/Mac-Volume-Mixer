// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Soundboard",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SoundboardApp", targets: ["SoundboardApp"]),
    ],
    targets: [
        .target(
            name: "AudioRouterCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SoundboardApp",
            dependencies: ["AudioRouterCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AudioRouterCoreTests",
            dependencies: ["AudioRouterCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
