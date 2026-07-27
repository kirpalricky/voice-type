// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceType",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", "0.15.0"..<"0.16.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", "1.7.0"..<"1.10.0"),
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.8.0")
    ],
    targets: [
        .executableTarget(
            name: "VoiceType",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ]
        ),
        .testTarget(
            name: "VoiceTypeTests",
            dependencies: [
                "VoiceType",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ]
)
