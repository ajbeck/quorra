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
    ],
    dependencies: [
        .package(
            url: "https://github.com/awslabs/aws-sdk-swift",
            from: "1.0.0"
        )
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
        .target(
            name: "IAMIdentityCenter",
            dependencies: [
                .product(name: "AWSSSOOIDC", package: "aws-sdk-swift"),
                .product(name: "AWSSSO", package: "aws-sdk-swift"),
            ]
        ),
        .testTarget(
            name: "IAMIdentityCenterTests",
            dependencies: ["IAMIdentityCenter"]
        ),
    ]
)
