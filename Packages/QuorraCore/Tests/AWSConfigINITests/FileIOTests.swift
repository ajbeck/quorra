// FileIOTests.swift — tests the locked file IO API.
//
// Covers Document.update(at:flavor:_:) round-trip, file-not-found-as-empty,
// atomic-rename hygiene (no leftover .tmp), sequential read-modify-write
// accumulation, cross-process serialization, and the .lockTimeout path.

import Testing
import Foundation
import Darwin
@testable import AWSConfigINI

@Suite("File IO")
struct FileIOTests {

    // MARK: - Helpers

    /// Creates a fresh temp directory, yields its URL to the block, then
    /// removes it in a defer. Callers use this for isolation.
    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quorra_fileio_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func lockHelperURL() throws -> URL {
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("AWSConfigINILockTestHelper")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    @discardableResult
    private func runHelper(_ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = try lockHelperURL()
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        return process
    }

    private func waitForFile(at url: URL, timeout: TimeInterval = 2.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    // MARK: - Single-threaded round-trip (plan §11.3 DoD item 1)

    @Test func writeAndRereadRoundTrip() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("config")

            // Write a key via update(at:).
            try AWSConfigINIDocument.update(at: url, flavor: .config) { doc in
                doc.ensureSection("default")
                doc.update("default") { s in
                    s.setKey("region", value: "us-east-1")
                    s.setKey("output", value: "json")
                }
            }

            // Read back independently.
            let doc = try AWSConfigINIDocument(contentsOf: url)
            #expect(doc.section("default")?.key("region")?.stringValue == "us-east-1")
            #expect(doc.section("default")?.key("output")?.stringValue == "json")
        }
    }

    // MARK: - File-not-found → empty document (plan §11.3 DoD, M05 spec)

    @Test func missingFileCreatedFromScratch() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("new_config")

            // File does not exist. update(at:) must treat it as empty and write.
            try AWSConfigINIDocument.update(at: url, flavor: .credentials) { doc in
                #expect(doc.sections.isEmpty, "missing file must parse as empty document")
                #expect(doc.flavor == .credentials)
                doc.ensureSection("dev")
                doc.update("dev") { s in
                    s.setKey("aws_access_key_id", value: "AKIAIOSFODNN7EXAMPLE")
                }
            }

            let doc = try AWSConfigINIDocument(contentsOf: url, flavor: .credentials)
            #expect(doc.section("dev")?.key("aws_access_key_id")?.stringValue == "AKIAIOSFODNN7EXAMPLE")
        }
    }

    // MARK: - Atomic-rename: no .tmp leftover on success (plan §11.3 DoD item 4)

    @Test func noTmpFileLeftoverOnSuccess() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("config")

            try AWSConfigINIDocument.update(at: url, flavor: .config) { doc in
                doc.ensureSection("default")
                doc.update("default") { s in s.setKey("region", value: "eu-west-1") }
            }

            // Check: no sibling .tmp file should remain after a successful write.
            // Foundation's Data.write(to:options:.atomic) cleans up its temp file.
            // We also verify the data file itself exists and the lock file was left
            // (it is intentionally not cleaned up per plan §11 "Lock file naming").
            #expect(FileManager.default.fileExists(atPath: url.path),
                    "data file must exist after update")

            // Lock file is intentionally left on disk.
            let lockPath = url.path + ".lock"
            #expect(FileManager.default.fileExists(atPath: lockPath),
                    "lock file is intentionally left on disk (synchronization point)")

            // No .tmp file (Foundation's .atomic rename leaves none on success).
            // Foundation uses a UUID-named temp in the same directory, not url.path+".tmp",
            // but we can assert the exact path variant from AtomicWrite is absent.
            let tmpPath = url.path + ".tmp"
            #expect(!FileManager.default.fileExists(atPath: tmpPath),
                    "no .tmp file should remain after successful atomic write")
        }
    }

    // MARK: - Incremental update (second call merges with existing)

    @Test func secondCallMergesWithExistingContent() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("config")

            // First write.
            try AWSConfigINIDocument.update(at: url, flavor: .config) { doc in
                doc.ensureSection("default")
                doc.update("default") { s in s.setKey("region", value: "us-east-1") }
            }

            // Second write: add a new key without touching region.
            try AWSConfigINIDocument.update(at: url, flavor: .config) { doc in
                doc.update("default") { s in s.setKey("output", value: "table") }
            }

            let doc = try AWSConfigINIDocument(contentsOf: url)
            // Both keys must be present.
            #expect(doc.section("default")?.key("region")?.stringValue == "us-east-1")
            #expect(doc.section("default")?.key("output")?.stringValue == "table")
        }
    }

    // MARK: - Sequential read-modify-write accumulation (plan §11.3 DoD item 2)
    //
    // Two sequential update(at:_:) calls each increment a counter key.
    // The second call reads the state written by the first. Final count must be 2.
    //
    // NOTE on same-process fcntl locking vs. cross-process:
    //   POSIX/Darwin fcntl byte-range locks are per-process, not per-fd.
    //   A second open(2)+F_SETLK from the same PID always succeeds immediately
    //   — it does NOT block waiting for the same process's prior lock holder.
    //   This means in-process concurrent Tasks cannot race-test the fcntl path.
    //   The real-world serialization guarantee is cross-process: app vs. CLI
    //   (CLAUDE.md "App ↔ CLI Architecture"). Cross-process serialization is
    //   verified below by integration-style tests that spawn helper processes.
    //
    // What this test verifies:
    //   - The read-modify-write cycle in update(at:_:) is correct end-to-end.
    //   - Each call correctly reads the state written by the previous call.
    //   - Sequential calls accumulate without data loss.

    @Test func lockContentionCounterReachesTwo() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("config")

            // Seed the file with counter = 0.
            try AWSConfigINIDocument.update(at: url, flavor: .config) { doc in
                doc.ensureSection("state")
                doc.update("state") { s in s.setKey("counter", value: "0") }
            }

            // First increment: reads 0, writes 1.
            try AWSConfigINIDocument.update(at: url, flavor: .config) { doc in
                let current = doc.section("state")?.key("counter")?.intValue() ?? 0
                doc.update("state") { s in
                    s.setKey("counter", value: String(current + 1))
                }
            }

            // Second increment: reads 1, writes 2.
            try AWSConfigINIDocument.update(at: url, flavor: .config) { doc in
                let current = doc.section("state")?.key("counter")?.intValue() ?? 0
                doc.update("state") { s in
                    s.setKey("counter", value: String(current + 1))
                }
            }

            // Final read: counter must be 2 — no update was lost.
            let final = try AWSConfigINIDocument(contentsOf: url)
            let count = final.section("state")?.key("counter")?.intValue()
            #expect(count == 2,
                    "sequential update(at:) must accumulate correctly: expected counter=2, got \(count as Any)")
        }
    }

    // MARK: - lockTimeout test (plan §11.3 DoD item 3)

    @Test func lockTimeoutThrownWhenLockHeldByAnotherProcess() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("config")
            let readyURL = dir.appendingPathComponent("holder.ready")
            let holder = try runHelper(["hold-lock", url.path, readyURL.path, "2.0"])
            defer {
                if holder.isRunning {
                    holder.terminate()
                }
                holder.waitUntilExit()
            }

            #expect(waitForFile(at: readyURL), "helper process must acquire the lock before timeout assertion")

            let thrown = #expect(throws: AWSConfigINIError.self) {
                try FileLock.exclusive(on: url, timeout: 0.1) {
                    Issue.record("lock block must not execute while another process holds the lock")
                }
            }
            guard case .lockTimeout(let timedOutURL) = thrown else {
                Issue.record("Expected .lockTimeout, got: \(String(describing: thrown))")
                return
            }
            #expect(timedOutURL == url)
        }
    }

    @Test func crossProcessUpdatesSerializeWithoutLostIncrement() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("config")

            try AWSConfigINIDocument.update(at: url, flavor: .config) { doc in
                doc.ensureSection("state")
                doc.update("state") { s in s.setKey("counter", value: "0") }
            }

            let first = try runHelper(["increment", url.path, "0.2"])
            let second = try runHelper(["increment", url.path, "0.2"])
            first.waitUntilExit()
            second.waitUntilExit()

            #expect(first.terminationStatus == 0)
            #expect(second.terminationStatus == 0)

            let final = try AWSConfigINIDocument(contentsOf: url)
            let count = final.section("state")?.key("counter")?.intValue()
            #expect(count == 2, "cross-process update(at:) calls must serialize: expected counter=2, got \(count as Any)")
        }
    }
}
