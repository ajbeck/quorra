// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "QuorraCore",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "AWSConfigINI", targets: ["AWSConfigINI"]),
        .library(name: "IAMIdentityCenter", targets: ["IAMIdentityCenter"]),
        .library(name: "QuorraAppLogic", targets: ["QuorraAppLogic"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/awslabs/aws-sdk-swift",
            from: "1.0.0"
        )
    ],
    targets: [
        .target(name: "AWSConfigINI"),
        .executableTarget(
            name: "AWSConfigINILockTestHelper",
            dependencies: ["AWSConfigINI"],
            path: "Tests/AWSConfigINILockTestHelper"
        ),
        .testTarget(
            name: "AWSConfigINITests",
            dependencies: ["AWSConfigINI", "AWSConfigINILockTestHelper"],
            resources: [
                .copy("Resources"),
            ]
        ),
        .target(
            name: "IAMIdentityCenter",
            dependencies: [
                .product(name: "AWSSSOOIDC", package: "aws-sdk-swift"),
                .product(name: "AWSSSO", package: "aws-sdk-swift"),
            ]
        ),
        .target(
            name: "QuorraAppLogic",
            dependencies: ["AWSConfigINI", "IAMIdentityCenter"]
        ),
        .testTarget(
            name: "QuorraAppLogicTests",
            dependencies: ["QuorraAppLogic", "AWSConfigINI", "IAMIdentityCenter"]
        ),
        .testTarget(
            name: "IAMIdentityCenterTests",
            dependencies: ["IAMIdentityCenter"]
        ),
    ]
)
