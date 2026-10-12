import Foundation

/// Packages reviewed native objects and their source/notice material for SwiftPM.
public enum ClientVPNCorePackage {
    public static let packagePath = "Packages/QuorraOpenVPN"

    static func fileDigests(in root: URL) throws -> [String: String] {
        try require(exists(root.path), "Cannot read native package artifacts.")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw ToolingFailure("Cannot read native package artifacts.")
        }
        var result: [String: String] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            try require(values.isSymbolicLink != true, "Native package artifacts must not contain symbolic links.")
            if values.isRegularFile == true {
                let path = String(url.path.dropFirst(root.path.count + 1))
                result[path] = digest(try read(url.path))
            }
        }
        return result
    }

    static func recipeDigests(root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for file in ["ClientVPNCoreReview.swift", "ClientVPNCorePackage.swift"] {
            result["Recipe/\(file)"] = digest(try read(root.appendingPathComponent("Tooling/Sources/QuorraTooling/\(file)").path))
        }
        for (path, hash) in try fileDigests(in: root.appendingPathComponent(ClientVPNCoreReview.fixtureDirectory)) {
            result["Recipe/Fixtures/\(path)"] = hash
        }
        result["Recipe/SourceNotice.md"] = digest(try read(root.appendingPathComponent("\(packagePath)/SourceNotice.md").path))
        return result
    }

    static func copy(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    public static func build(root: URL, review: URL, output: URL) throws -> String {
        let pins = try ClientVPNCoreReview.sources(root: root)
        let fixtures = root.appendingPathComponent(ClientVPNCoreReview.fixtureDirectory)
        let library = review.appendingPathComponent("libQuorraOpenVPNCore.a")
        let evidence = String(decoding: try read(review.appendingPathComponent("results.txt").path), as: UTF8.self)
        try require(evidence.contains("SHA-256: \(digest(try read(library.path)))\n"), "Native core does not match its completed review.")
        // Review output carries the exact input copies, verified again here.
        for pin in pins { try ClientVPNCoreReview.verify(read(review.appendingPathComponent(pin.archive).path), source: pin) }
        try ClientVPNCoreReview.createOutput(output)
        func source(_ id: String) throws -> URL {
            guard let pin = pins.first(where: { $0.id == id }) else { throw ToolingFailure("Missing source pin.") }
            return review.appendingPathComponent("sources/\(id)/\(pin.directory)")
        }
        let headers = output.appendingPathComponent("headers")
        try FileManager.default.createDirectory(at: headers, withIntermediateDirectories: true)
        try copy(source("openvpn3").appendingPathComponent("openvpn"), to: headers.appendingPathComponent("openvpn"))
        try copy(source("openvpn3").appendingPathComponent("client/ovpncli.hpp"), to: headers.appendingPathComponent("client/ovpncli.hpp"))
        let asioHeaders = try source("asio").appendingPathComponent("include")
        for file in try FileManager.default.contentsOfDirectory(at: asioHeaders, includingPropertiesForKeys: nil) {
            try copy(file, to: headers.appendingPathComponent(file.lastPathComponent))
        }
        try copy(source("aws-lc").appendingPathComponent("include/openssl"), to: headers.appendingPathComponent("openssl"))
        try copy(source("lz4").appendingPathComponent("lib/lz4.h"), to: headers.appendingPathComponent("lz4.h"))
        try write("// C++ implementation headers are private to the Objective-C++ adapter.\n", headers.appendingPathComponent("QuorraOpenVPNCore.h").path)
        try write("module QuorraOpenVPNCore {\n    header \"QuorraOpenVPNCore.h\"\n    export *\n}\n", headers.appendingPathComponent("module.modulemap").path)
        let artifacts = output.appendingPathComponent("Artifacts")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        // There is no app build involved in this xcodebuild packaging operation.
        try Shell.foreground(["xcodebuild", "-create-xcframework", "-library", library.path, "-headers", headers.path,
                              "-output", artifacts.appendingPathComponent("QuorraOpenVPNCore.xcframework").path])
        let resources = output.appendingPathComponent("Resources")
        let notices: [(String, String, String)] = [
            ("openvpn3", "LICENSE.md", "OpenVPN.md"), ("openvpn3", "LICENSES/MPL-2.0.txt", "MPL-2.0.txt"),
            ("aws-lc", "LICENSE", "AWS-LC.txt"), ("asio", "LICENSE_1_0.txt", "Asio.txt"),
            ("lz4", "lib/LICENSE", "LZ4.txt"),
        ]
        for (id, file, name) in notices {
            try copy(source(id).appendingPathComponent(file), to: resources.appendingPathComponent("Licenses/\(name)"))
        }
        for id in ["openvpn3", "aws-patches"] {
            let pin = pins.first { $0.id == id }!
            try copy(review.appendingPathComponent(pin.archive), to: resources.appendingPathComponent("Source/\(pin.archive)"))
        }
        for patch in ClientVPNCoreReview.localPatches + ClientVPNCoreReview.rebasedAWSPatches.values.sorted() {
            try copy(fixtures.appendingPathComponent(patch), to: resources.appendingPathComponent("Source/\(patch)"))
        }
        try copy(fixtures.appendingPathComponent("sources.json"), to: resources.appendingPathComponent("Source/sources.json"))
        try copy(root.appendingPathComponent("\(packagePath)/SourceNotice.md"), to: resources.appendingPathComponent("Source/README.md"))
        try FileManager.default.removeItem(at: headers)
        var manifest = try fileDigests(in: output)
        manifest.merge(try recipeDigests(root: root)) { _, new in new }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try write(try encoder.encode(manifest) + Data([10]), output.appendingPathComponent("ArtifactManifest.json").path)
        return "Native SwiftPM artifacts and covered source prepared at \(output.path)."
    }

    public static func check(root: URL, rebuilt: URL? = nil) throws -> String {
        let package = root.appendingPathComponent(packagePath)
        let expected = try JSONDecoder().decode([String: String].self, from: read(package.appendingPathComponent("ArtifactManifest.json").path))
        var actual: [String: String] = [:]
        for (prefix, directory) in [("Artifacts", package.appendingPathComponent("Artifacts")), ("Resources", package.appendingPathComponent("Sources/QuorraOpenVPN/Resources"))] {
            for (path, hash) in try fileDigests(in: directory) { actual["\(prefix)/\(path)"] = hash }
        }
        actual.merge(try recipeDigests(root: root)) { _, new in new }
        try require(actual == expected, "Native VPN artifacts or build recipe differ from their manifest. Rebuild the package.")
        if let rebuilt {
            let comparison = try JSONDecoder().decode([String: String].self, from: read(rebuilt.appendingPathComponent("ArtifactManifest.json").path))
            try require(comparison == expected, "Rebuilt native VPN package differs from the committed artifacts.")
            var files = try fileDigests(in: rebuilt)
            files.removeValue(forKey: "ArtifactManifest.json")
            try require(files == expected.filter { !$0.key.hasPrefix("Recipe/") }, "Rebuilt native VPN files differ from their manifest.")
        }
        return "Native VPN artifacts, covered source and recipe match their manifest."
    }
}
