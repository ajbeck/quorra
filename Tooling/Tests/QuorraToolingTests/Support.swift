@testable import QuorraTooling
import Foundation
import Testing

/// The repository that contains this package.
let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A private temporary directory that is removed with the value.
final class Scratch {
    let url: URL
    var path: String { url.path }

    init(_ name: String) throws {
        // Resolve /var to /private/var, as the release stages do.
        let base = try Repository.resolved(FileManager.default.temporaryDirectory.path)
        url = URL(fileURLWithPath: base).appendingPathComponent("quorra-tooling-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ relative: String) -> String { url.appendingPathComponent(relative).path }

    /// Copies repository paths into the same relative places.
    func copy(_ paths: [String]) throws {
        for relative in paths {
            let destination = url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: repository.appendingPathComponent(relative), to: destination)
        }
    }
}

/// The message of the `ToolingFailure` that `body` throws.
func failure(_ body: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) -> String {
    do {
        try body()
        Issue.record("Expected a failure.", sourceLocation: sourceLocation)
        return ""
    } catch {
        return "\(error)"
    }
}

/// Runs a tool that must succeed, with its output discarded.
func tool(_ arguments: [String], directory: String? = nil) throws {
    let status = try Shell.run(arguments, output: .discard, directory: directory)
    try require(status == 0, "\(arguments[0]) exited \(status).")
}
