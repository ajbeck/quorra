// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "QuorraCore",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "AWSConfigINI", targets: ["AWSConfigINI"]),
    ],
    targets: [
        .target(name: "AWSConfigINI"),
        .testTarget(
            name: "AWSConfigINITests",
            dependencies: ["AWSConfigINI"],
            resources: [
                .copy("Resources"),
            ]
        ),
    ]
)
