// swift-tools-version: 6.2
import PackageDescription

// Developer tooling for Quorra: builds and checks the bundled OpenVPN core.
// It is a separate package so the app keeps its dependencies in the Xcode project.
let package = Package(
    name: "Tooling",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "quorra-tooling", targets: ["quorra-tooling"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", .upToNextMinor(from: "1.8.2")),
    ],
    targets: [
        .executableTarget(
            name: "quorra-tooling",
            dependencies: [
                "QuorraTooling",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(name: "QuorraTooling"),
        .testTarget(name: "QuorraToolingTests", dependencies: ["QuorraTooling", "quorra-tooling"]),
    ]
)
