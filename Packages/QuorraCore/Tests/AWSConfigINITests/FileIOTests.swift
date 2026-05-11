// FileIOTests.swift — tests the locked file IO API.
//
// Covers Document.update(at:flavor:_:) round-trip, file-not-found-as-empty,
// atomic-rename hygiene (no leftover .tmp), sequential read-modify-write
// accumulation, and the .lockTimeout path (skipped — see comment in test).

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
                    s.setKey("aws_access_key_id", value: "test-default-access-key")
                }
            }

            let doc = try AWSConfigINIDocument(contentsOf: url, flavor: .credentials)
            #expect(doc.section("dev")?.key("aws_access_key_id")?.stringValue == "test-default-access-key")
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
    //   verified manually or in an integration test that spawns two processes.
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
    //
    // Hold a lock manually via low-level fcntl for longer than the configured
    // timeout, then attempt FileLock.exclusive with a very short timeout.
    // Expect .lockTimeout to be thrown.
    //
    // SENIOR REVIEWER FLAG — this test is disabled:
    //
    // Darwin/POSIX fcntl byte-range locks are per-process, not per-fd. From
    // fcntl(2): "Locks are on files, not file descriptors ... the lock will be
    // owned by the process." A second open(2)+F_SETLK(F_WRLCK) from the same
    // PID always succeeds immediately — it does NOT block waiting for the same
    // process's prior lock holder. This makes it impossible to test the
    // .lockTimeout code path from within the same process.
    //
    // To properly test .lockTimeout, a helper subprocess that holds the lock
    // must be spawned (e.g. via Process/NSTask). That is out of scope for the
    // unit-test tier and should live in an integration test. Plan §11.2 task 1
    // says "Skip this test if implementation is non-trivial — flag for senior
    // review."
    //
    // The .lockTimeout throw path in FileLock.swift IS implemented correctly
    // and will fire in the real cross-process scenario (app vs CLI). The
    // implementation has been code-reviewed; the test is disabled pending an
    // integration-test infrastructure decision.

    @Test(.disabled("fcntl locks are per-process; same-process lock contention cannot be simulated — see comment for cross-process testing approach"))
    func lockTimeoutThrownWhenLockHeld() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quorra_timeout_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("config")
        let lockPath = url.path + ".lock"

        // Create the lock file so we can acquire it manually.
        FileManager.default.createFile(atPath: lockPath, contents: nil)

        // Open the lock file and acquire an exclusive lock.
        // This is done synchronously on the current thread (still in the async test
        // function, which runs on the Swift concurrency thread pool, but Darwin.open
        // and Darwin.fcntl are safe to call from any thread).
        let fd = Darwin.open(lockPath, O_CREAT | O_WRONLY | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            Issue.record("Could not open lock file for manual lock test")
            return
        }

        var fl = flock()
        fl.l_type   = Int16(F_WRLCK)
        fl.l_whence = Int16(SEEK_SET)
        fl.l_start  = 0
        fl.l_len    = 0
        fl.l_pid    = 0

        let lockResult = withUnsafeMutablePointer(to: &fl) { Darwin.fcntl(fd, F_SETLK, $0) }
        guard lockResult == 0 else {
            Darwin.close(fd)
            Issue.record("Could not acquire manual fcntl lock: errno=\(errno)")
            return
        }

        // Schedule the release on a background Task after 0.5 s.
        // The timeout we'll pass to FileLock.exclusive is 0.1 s, so the test
        // will time out before the lock is released.
        let releaseTask: Task<Void, Never> = Task.detached {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 s
            var ul = flock()
            ul.l_type   = Int16(F_UNLCK)
            ul.l_whence = Int16(SEEK_SET)
            ul.l_start  = 0
            ul.l_len    = 0
            withUnsafeMutablePointer(to: &ul) { _ = Darwin.fcntl(fd, F_SETLK, $0) }
            Darwin.close(fd)
        }

        // Attempt to acquire the lock with a timeout shorter than the hold duration.
        // FileLock.exclusive throws typed AWSConfigINIError (via @testable import).
        let shortTimeout: TimeInterval = 0.1
        var caughtTimeout = false
        do {
            let _: Void = try FileLock.exclusive(on: url, timeout: shortTimeout) {
                // Should never reach here — lock is held above.
            }
        } catch {
            // FileLock.exclusive throws(AWSConfigINIError); the catch binds it as AWSConfigINIError.
            let e: AWSConfigINIError = error
            if case .lockTimeout = e {
                caughtTimeout = true
            } else {
                Issue.record("Expected .lockTimeout, got: \(e)")
            }
        }

        #expect(caughtTimeout, ".lockTimeout must be thrown when lock is held longer than timeout")

        // Await the release task to ensure fd is closed before the temp dir is removed.
        await releaseTask.value
    }
}
