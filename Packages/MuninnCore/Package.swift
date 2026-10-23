// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MuninnCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MuninnCore", targets: ["MuninnCore"]),
    ],
    targets: [
        .target(
            name: "MuninnCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MuninnCoreTests",
            dependencies: ["MuninnCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
