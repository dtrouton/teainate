// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "teainate",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TeainateCore", targets: ["TeainateCore"]),
        .executable(name: "teainate", targets: ["teainate"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "TeainateCore"),
        .executableTarget(
            name: "teainate",
            dependencies: [
                "TeainateCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "TeainateCoreTests", dependencies: ["TeainateCore"]),
    ],
    swiftLanguageModes: [.v6]
)
