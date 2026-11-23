// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Macximesed",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MacxCore", targets: ["MacxCore"]),
        .executable(name: "macx", targets: ["macx"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2")
    ],
    targets: [
        .target(name: "MacxCore"),
        .executableTarget(
            name: "macx",
            dependencies: [
                "MacxCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "MacxCoreTests", dependencies: ["MacxCore"]),
    ]
)
