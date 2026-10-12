import Foundation

/// Builds the pinned native dependency in a new directory. Never installs or connects.
public enum ClientVPNCoreReview {
    struct Source: Codable, Equatable {
        let id: String
        let version: String
        let revision: String?
        let archive: String
        let directory: String
        let url: String
        let sha256: String
    }

    static let fixtureDirectory = "Tooling/Fixtures/ClientVPNCoreReview"
    /// Quorra ships for Apple silicon only.
    static let architectures = ["arm64"]
    static let localPatches = ["001-crv1-username.patch", "002-awslc-certificate-policy.patch"]
    static let awsPatches = [
        "000-aws-lc-integration.patch", "001-support-saml.patch",
        "002-windows-tunbuilder-client.patch", "003-default-delay.patch",
        "004-fips-cipher-restriction.patch", "005-mssfix-default.patch",
        "006-allow-static-keepalive-and-ping-exit.patch",
    ]
    /// AWS patches whose context no longer matches the pinned OpenVPN release.
    /// The fixture copy, with only that context updated, is applied in place of AWS's copy.
    static let rebasedAWSPatches = ["001-support-saml.patch": "001-support-saml-3.11.7.patch"]

    static func sources(root: URL) throws -> [Source] {
        try JSONDecoder().decode([Source].self, from: read(root.appendingPathComponent("\(fixtureDirectory)/sources.json").path))
    }

    static func verify(_ data: Data, source: Source) throws {
        try require(digest(data) == source.sha256, "Checksum mismatch for \(source.archive).")
    }

    static func validateArchiveListing(_ listing: String, source: Source) throws {
        let entries = listing.split(separator: "\n")
        try require(!entries.isEmpty, "Empty source archive.")
        for entry in entries {
            let components = entry.split(separator: "/", omittingEmptySubsequences: false)
            try require(!entry.hasPrefix("/") && !components.contains(".."), "Unsafe source archive path.")
            // AWS's published archive includes AppleDouble metadata.
            try require(components.first == Substring(source.directory) || entry == "._\(source.directory)", "Unexpected source archive root.")
        }
    }

    static func createOutput(_ output: URL) throws {
        try require(!exists(output.path), "Review output already exists; choose a new directory.")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    static func cmakePrefixMap(_ output: URL) -> String {
        var delimiter = "="
        let flag = "-ffile-prefix-map=\(output.path)=/quorra/native-review"
        while flag.contains("]\(delimiter)]") { delimiter += "=" }
        return "add_compile_options([\(delimiter)[\(flag)]\(delimiter)])\n"
    }

    static func cmakeArguments(source: URL, build: URL, architecture: String, options: URL, sdk: String) -> [String] {
        ["-S", source.path, "-B", build.path,
         "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_DEPLOYMENT_TARGET=26.0",
         "-DCMAKE_OSX_ARCHITECTURES=\(architecture)", "-DCMAKE_OSX_SYSROOT=\(sdk)",
         "-DCMAKE_SYSTEM_NAME=Darwin", "-DCMAKE_SYSTEM_PROCESSOR=\(architecture)",
         "-DCMAKE_PROJECT_TOP_LEVEL_INCLUDES=\(options.path)",
         "-DCMAKE_C_COMPILER=/usr/bin/clang", "-DCMAKE_CXX_COMPILER=/usr/bin/clang++",
         "-DBUILD_TESTING=OFF", "-DBUILD_TOOL=OFF", "-DBUILD_SHARED_LIBS=OFF",
         "-DDISABLE_GO=ON", "-DENABLE_SOURCE_MODIFICATION=OFF"]
    }

    /// Explicit opt-in for CI and dependency updates. Hash every download before use.
    public static func download(root: URL, archives: URL) throws {
        try createOutput(archives)
        for pin in try sources(root: root) {
            let file = archives.appendingPathComponent(pin.archive)
            try Shell.foreground(["curl", "--disable", "--proto", "=https", "--proto-redir", "=https", "--tlsv1.2",
                                  "--fail", "--location", "--silent", "--show-error", "--max-filesize", "268435456",
                                  "--output", file.path, pin.url])
            try verify(read(file.path), source: pin)
        }
    }

    public static func build(root: URL, archives: URL, output: URL) throws -> String {
        let pins = try sources(root: root)
        // Validate every input before running any downloaded build tool or source.
        for source in pins {
            try verify(read(archives.appendingPathComponent(source.archive).path), source: source)
        }
        try createOutput(output)
        let output = URL(fileURLWithPath: try Repository.resolved(output.path))
        let fixtures = root.appendingPathComponent(fixtureDirectory)
        let environment = ["ZERO_AR_DATE": "1", "LC_ALL": "C"]
        var step = 0
        func run(_ arguments: [String], directory: String? = nil) throws {
            step += 1
            let log = output.appendingPathComponent(String(format: "%03d-build.log", step))
            let status = try Shell.run(arguments, output: .file(log.path), environment: environment, directory: directory)
            try require(status == 0, "Native review step \(step) failed. See \(log.path).")
        }
        var directories: [String: URL] = [:]
        for source in pins {
            let extraction = output.appendingPathComponent("sources/\(source.id)")
            try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
            let archive = output.appendingPathComponent(source.archive)
            try FileManager.default.copyItem(at: archives.appendingPathComponent(source.archive), to: archive)
            // Verify the actual copy we will extract as well.
            try verify(read(archive.path), source: source)
            let listing = try Shell.text(["/usr/bin/tar", "-tzf", archive.path])
            try validateArchiveListing(listing, source: source)
            try run(["/usr/bin/tar", "-xzf", archive.path, "--no-same-owner", "-C", extraction.path])
            directories[source.id] = extraction.appendingPathComponent(source.directory)
        }
        guard let core = directories["openvpn3"], let aws = directories["aws-patches"],
              let tls = directories["aws-lc"], let asio = directories["asio"],
              let lz4 = directories["lz4"], let cmakeRoot = directories["cmake"] else {
            throw ToolingFailure("Incomplete native core source manifest.")
        }
        let cmake = cmakeRoot.appendingPathComponent("CMake.app/Contents/bin/cmake").path
        let awsInputs = awsPatches.map { rebasedAWSPatches[$0].map(fixtures.appendingPathComponent) ?? aws.appendingPathComponent($0) }
        for patch in awsInputs + localPatches.map({ fixtures.appendingPathComponent($0) }) {
            try run(["/usr/bin/patch", "--batch", "--forward", "--fuzz=0", "-p1", "-i", patch.path], directory: core.path)
        }
        let sdk = try Shell.text(["xcrun", "--show-sdk-path"])
        let compiler = try Shell.text(["xcrun", "clang", "--version"])
        let version = try Shell.text([cmake, "--version"])
        try require(version.hasPrefix("cmake version 4.4.4\n"), "Unexpected CMake version.")
        try write(compiler + "\n" + version + "\nSDK: " + sdk + "\n", output.appendingPathComponent("toolchain.txt").path)

        let ca = try read(root.appendingPathComponent("Packages/QuorraCore/Tests/DatabaseProxyTests/Fixtures/ProxyTLS/proxy-test-root.der").path)
        let pem = "-----BEGIN CERTIFICATE-----\n" + ca.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]) + "\n-----END CERTIFICATE-----\n"
        let caFile = output.appendingPathComponent("synthetic-ca.pem")
        try write(pem, caFile.path)
        let compileOptions = output.appendingPathComponent("prefix-map.cmake")
        try write(cmakePrefixMap(output), compileOptions.path)
        var libraries: [String] = []
        var checks: [String] = []
        for architecture in architectures {
            print("Building native core review for \(architecture)…")
            let build = output.appendingPathComponent(architecture)
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            let tlsBuild = build.appendingPathComponent("aws-lc")
            let prefixMap = "-ffile-prefix-map=\(output.path)=/quorra/native-review"
            try run([cmake] + cmakeArguments(source: tls, build: tlsBuild, architecture: architecture, options: compileOptions, sdk: sdk))
            try run([cmake, "--build", tlsBuild.path, "--target", "ssl", "--parallel", "8"])
            let common = ["-O2", "-arch", architecture, "-mmacosx-version-min=26.0", "-isysroot", sdk,
                          "-fvisibility=hidden", "-fvisibility-inlines-hidden", prefixMap,
                          "-ffile-prefix-map=\(fixtures.path)=/quorra/native-review/checks"]
            let includes = [core, asio.appendingPathComponent("asio/include"), tls.appendingPathComponent("include"), lz4.appendingPathComponent("lib")].map { "-I\($0.path)" }
            let flags = common + ["-std=c++17"] + includes + ["-DASIO_STANDALONE", "-DUSE_ASIO", "-DUSE_OPENSSL", "-DHAVE_LZ4", "-DOPENVPN_EXTERNAL_TUN_FACTORY", "-DOPENVPN_CORE_API_VISIBILITY_HIDDEN"]
            var objects: [String] = []
            for (file, name) in [(core.appendingPathComponent("client/ovpncli.cpp"), "ovpncli"), (core.appendingPathComponent("openvpn/crypto/data_epoch.cpp"), "data_epoch")] {
                let object = build.appendingPathComponent("\(name).o").path
                try run(["xcrun", "clang++"] + flags + ["-c", file.path, "-o", object])
                objects.append(object)
            }
            let lz4Object = build.appendingPathComponent("lz4.o").path
            try run(["xcrun", "clang"] + common + ["-c", lz4.appendingPathComponent("lib/lz4.c").path, "-o", lz4Object])
            let tlsLibraries = [tlsBuild.appendingPathComponent("ssl/libssl.a").path, tlsBuild.appendingPathComponent("crypto/libcrypto.a").path]
            let library = build.appendingPathComponent("libQuorraOpenVPNCore.a").path
            try run(["xcrun", "libtool", "-static", "-o", library] + objects + [lz4Object] + tlsLibraries)
            libraries.append(library)

            for name in ["CoreChecks", "ProtocolChecks"] {
                let binary = build.appendingPathComponent(name).path
                // ProtocolChecks is separate: it instantiates protocol internals
                // with silent logging, without changing the client library's ODR.
                let inputs = name == "CoreChecks" ? [library] : [objects[1], lz4Object] + tlsLibraries
                try run(["xcrun", "clang++"] + flags + [fixtures.appendingPathComponent("\(name).cpp").path] + inputs + ["-framework", "CoreFoundation", "-framework", "SystemConfiguration", "-o", binary])
                let result = try Shell.capture(["/usr/bin/arch", "-\(architecture)", binary] + (name == "CoreChecks" ? [caFile.path] : []), errors: .merge)
                try require(result.status == 0, "\(name) failed for \(architecture); no network connection was attempted.")
                let text = String(decoding: result.output, as: UTF8.self)
                print(text, terminator: "")
                checks.append("\(architecture): \(text)")
            }
        }
        let universal = output.appendingPathComponent("libQuorraOpenVPNCore.a")
        try run(["xcrun", "lipo", "-create"] + libraries + ["-output", universal.path])
        let slices = try Shell.text(["xcrun", "lipo", "-archs", universal.path])
        try require(Set(slices.split(separator: " ").map(String.init)) == Set(architectures), "Native core architecture check failed.")
        let checksum = digest(try read(universal.path))
        try write(checks.joined() + "\nArchitectures: \(slices)\nSHA-256: \(checksum)\n", output.appendingPathComponent("results.txt").path)
        return "Offline native core review passed. Library SHA-256: \(checksum)\nEvidence: \(output.path)"
    }
}
