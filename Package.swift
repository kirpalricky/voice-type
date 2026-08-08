// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Yapboard",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", "0.15.0"..<"0.16.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", "1.7.0"..<"4.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.8.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", "8.36.0"..<"10.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Yapboard",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Sentry", package: "sentry-cocoa")
            ],
            exclude: [
                "Resources/AppIcon.icns",
                "Resources/Info.plist",
                "Secrets.swift.example"
            ]
        ),
        .testTarget(
            name: "YapboardTests",
            dependencies: [
                "Yapboard",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ]
)
