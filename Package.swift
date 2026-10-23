// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LDManager",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LDCore", targets: ["LDCore"]),
        .executable(name: "ldm", targets: ["ldm"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "LDCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "ldm",
            dependencies: ["LDCore", .product(name: "ArgumentParser", package: "swift-argument-parser")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "LDCoreTests", dependencies: ["LDCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
