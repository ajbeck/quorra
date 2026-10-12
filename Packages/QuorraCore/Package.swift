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
        .library(name: "DatabaseProxy", targets: ["DatabaseProxy"]),
        .library(name: "QuorraProfiles", targets: ["QuorraProfiles"]),
        .library(name: "QuorraIPC", targets: ["QuorraIPC"]),
        .library(name: "QuorraAppLogic", targets: ["QuorraAppLogic"]),
        .library(name: "QuorraCLIKit", targets: ["QuorraCLIKit"]),
        .executable(name: "quorra-cli", targets: ["QuorraCLIExecutable"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.8.2"
        ),
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
            ]
        ),
        .target(
            name: "DatabaseProxy",
            dependencies: [
                "IAMIdentityCenter",
                .product(name: "AWSRDS", package: "aws-sdk-swift"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "DatabaseProxyTests",
            dependencies: ["DatabaseProxy", "IAMIdentityCenter"],
            resources: [
                .process("Fixtures"),
            ]
        ),
        .target(
            name: "QuorraAppLogic",
            dependencies: ["AWSConfigINI", "DatabaseProxy", "IAMIdentityCenter", "QuorraIPC", "QuorraProfiles"]
        ),
        .target(
            name: "QuorraProfiles",
            dependencies: ["AWSConfigINI"]
        ),
        .target(
            name: "QuorraIPC"
        ),
        .target(
            name: "QuorraCLIKit",
            dependencies: [
                "QuorraIPC",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "QuorraCLIExecutable",
            dependencies: ["QuorraCLIKit"]
        ),
        .testTarget(
            name: "QuorraCLITests",
            dependencies: ["QuorraCLIKit", "QuorraIPC"]
        ),
        .testTarget(
            name: "QuorraIPCTests",
            dependencies: ["QuorraIPC"]
        ),
        .testTarget(
            name: "QuorraProfilesTests",
            dependencies: ["QuorraProfiles", "AWSConfigINI"]
        ),
        .testTarget(
            name: "QuorraAppLogicTests",
            dependencies: ["QuorraAppLogic", "AWSConfigINI", "DatabaseProxy", "IAMIdentityCenter"]
        ),
        .testTarget(
            name: "IAMIdentityCenterTests",
            dependencies: ["IAMIdentityCenter"]
        ),
    ]
)
