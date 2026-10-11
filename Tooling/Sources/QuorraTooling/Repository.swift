import CryptoKit
import Foundation

public enum Repository {
    /// The nearest directory at or above `start` that contains `quorra.xcodeproj`.
    public static func root(from start: String = FileManager.default.currentDirectoryPath) throws -> URL {
        var directory = URL(fileURLWithPath: start, isDirectory: true).standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("quorra.xcodeproj").path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            try require(parent.path != directory.path, "Run quorra-tooling inside the Quorra repository, or pass --root.")
            directory = parent
        }
    }

    /// The physical path, as `pwd -P` gives.
    public static func resolved(_ path: String) throws -> String {
        guard let value = realpath(path, nil) else { throw ToolingFailure("Cannot resolve \(URL(fileURLWithPath: path).lastPathComponent).") }
        defer { free(value) }
        return String(cString: value)
    }
}

func read(_ path: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }

func write(_ data: Data, _ path: String) throws { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }

func write(_ text: String, _ path: String) throws { try write(Data(text.utf8), path) }

func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
