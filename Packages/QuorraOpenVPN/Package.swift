// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "QuorraOpenVPN",
    platforms: [.macOS(.v26)],
    products: [.library(name: "QuorraOpenVPN", targets: ["QuorraOpenVPN"])],
    targets: [
        .binaryTarget(name: "QuorraOpenVPNCore", path: "Artifacts/QuorraOpenVPNCore.xcframework"),
        .target(
            name: "QuorraOpenVPNNative",
            dependencies: ["QuorraOpenVPNCore"],
            cxxSettings: [
                .define("ASIO_STANDALONE"), .define("USE_ASIO"),
                .define("USE_OPENSSL"), .define("HAVE_LZ4"),
                .define("OPENVPN_EXTERNAL_TUN_FACTORY"),
                .define("OPENVPN_CORE_API_VISIBILITY_HIDDEN"),
            ],
            linkerSettings: [.linkedFramework("NetworkExtension"), .linkedFramework("SystemConfiguration")]
        ),
        .target(name: "QuorraOpenVPN", dependencies: ["QuorraOpenVPNNative"], resources: [.copy("Resources")]),
        .target(
            name: "QuorraOpenVPNTestSupport",
            dependencies: ["QuorraOpenVPNNative", "QuorraOpenVPNCore"],
            path: "Tests/NativeSupport",
            cxxSettings: [
                .define("ASIO_STANDALONE"), .define("USE_ASIO"), .define("USE_OPENSSL"), .define("HAVE_LZ4"),
                .define("OPENVPN_EXTERNAL_TUN_FACTORY"), .define("OPENVPN_CORE_API_VISIBILITY_HIDDEN"),
            ]
        ),
        .testTarget(name: "QuorraOpenVPNTests", dependencies: ["QuorraOpenVPN", "QuorraOpenVPNNative", "QuorraOpenVPNTestSupport"], resources: [.copy("Fixtures")]),
    ],
    cxxLanguageStandard: .cxx17
)
