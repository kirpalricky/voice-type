// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceType",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.1.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", "1.7.0"..<"1.10.0")
    ],
    targets: [
        .executableTarget(
            name: "VoiceType",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ]
        )
    ]
)
