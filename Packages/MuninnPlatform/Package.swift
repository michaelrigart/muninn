// swift-tools-version: 6.0
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "MuninnPlatform",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MuninnAudio", targets: ["MuninnAudio"]),
        .library(name: "MuninnSpeech", targets: ["MuninnSpeech"]),
        .library(name: "MuninnSystem", targets: ["MuninnSystem"]),
        .executable(name: "muninn-spike", targets: ["MuninnSpike"]),
    ],
    dependencies: [
        .package(path: "../MuninnCore"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "MuninnAudio",
            dependencies: ["MuninnCore"],
            swiftSettings: swift5
        ),
        .target(
            name: "MuninnSpeech",
            dependencies: [
                "MuninnCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            swiftSettings: swift5
        ),
        .target(
            name: "MuninnSystem",
            dependencies: ["MuninnCore"],
            swiftSettings: swift5
        ),
        .executableTarget(
            name: "MuninnSpike",
            dependencies: [
                "MuninnCore", "MuninnAudio", "MuninnSpeech", "MuninnSystem",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: swift5
        ),
        .testTarget(
            name: "MuninnAudioTests",
            dependencies: ["MuninnAudio", "MuninnCore"],
            swiftSettings: swift5
        ),
        .testTarget(
            name: "MuninnSpeechTests",
            dependencies: ["MuninnSpeech", "MuninnCore"],
            swiftSettings: swift5
        ),
        .testTarget(
            name: "MuninnSystemTests",
            dependencies: ["MuninnSystem", "MuninnCore"],
            swiftSettings: swift5
        ),
    ]
)
