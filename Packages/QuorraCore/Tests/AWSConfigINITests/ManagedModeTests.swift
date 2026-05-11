// ManagedModeTests.swift — tests the managed/read-only mode contract.
//
// Covers managed-write header prepend (idempotent + insertion-order),
// read-only fail-fast throws on both write(to:) and update(at:_:), custom
// header text, and the read-after-managed-write round-trip.

import Testing
import Foundation
@testable import AWSConfigINI

@Suite("Managed mode")
struct ManagedModeTests {

    // MARK: - Helpers

    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quorra_m08_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private var defaultHeader: String {
        AWSConfigINIDocumentOptions.default.managedHeaderText
    }

    // MARK: - write(to:mode:) — managed

    /// A fresh document written in managed mode must have the managed-mode header
    /// as the first leading comment in the serialized output.
    @Test func managedWriteFreshDocumentHasHeader() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("config")

            var doc = AWSConfigINIDocument(empty: .config)
            doc.ensureSection("default")
            doc.update("default") { s in s.setKey("region", value: "us-east-1") }

            try doc.write(to: url, mode: .managed)

            let reloaded = try AWSConfigINIDocument(contentsOf: url)
            #expect(
                reloaded.leadingComments.first == defaultHeader,
                "managed write of fresh doc must prepend header; got: \(reloaded.leadingComments)"
            )
        }
    }

    /// Writing an already-headered document in managed mode must NOT duplicate the header.
    @Test func managedWriteAlreadyHeadedDocumentDoesNotDuplicate() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("config")

            var doc = AWSConfigINIDocument(empty: .config)
            doc.leadingComments = [defaultHeader]
            doc.ensureSection("default")
            doc.update("default") { s in s.setKey("region", value: "eu-west-1") }

            // Write twice.
            try doc.write(to: url, mode: .managed)
            // Now reload and write again.
            let reloaded = try AWSConfigINIDocument(contentsOf: url)
            try reloaded.write(to: url, mode: .managed)

            let final = try AWSConfigINIDocument(contentsOf: url)
            let headerCount = final.leadingComments.filter { $0 == defaultHeader }.count
            #expect(headerCount == 1, "header must appear exactly once; got leading comments: \(final.leadingComments)")
        }
    }

    /// A document with a different leading comment — managed write must prepend the
    /// header AHEAD of the existing comment, preserving the existing comment after it.
    @Test func managedWritePrependsHeaderBeforeExistingComments() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("config")

            var doc = AWSConfigINIDocument(empty: .config)
            let existingComment = "# My existing comment"
            doc.leadingComments = [existingComment]
            doc.ensureSection("default")
            doc.update("default") { s in s.setKey("region", value: "ap-southeast-1") }

            try doc.write(to: url, mode: .managed)

            let reloaded = try AWSConfigINIDocument(contentsOf: url)
            #expect(
                reloaded.leadingComments.count >= 2,
                "header + existing comment must both be present"
            )
            #expect(
                reloaded.leadingComments.first == defaultHeader,
                "header must be first; got: \(reloaded.leadingComments)"
            )
            #expect(
                reloaded.leadingComments.contains(existingComment),
                "existing comment must be preserved; got: \(reloaded.leadingComments)"
            )
        }
    }

    // MARK: - write(to:mode:) — read-only

    /// write(to:mode:.readOnly) must throw .readOnly and must NOT create the file.
    @Test func readOnlyWriteThrowsReadOnly() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("config")

            var doc = AWSConfigINIDocument(empty: .config)
            doc.ensureSection("default")

            var caught = false
            do {
                try doc.write(to: url, mode: .readOnly)
            } catch let e as AWSConfigINIError {
                if case .readOnly(let u) = e {
                    caught = true
                    #expect(u == url, ".readOnly must carry the target URL")
                } else {
                    Issue.record("Expected .readOnly, got: \(e)")
                }
            }
            #expect(caught, ".readOnly must be thrown by write(to:mode:.readOnly)")

            // No file must have been created.
            #expect(
                !FileManager.default.fileExists(atPath: url.path),
                "read-only write must not create the file"
            )
        }
    }

    // MARK: - update(at:mode:) — read-only

    /// update(at:mode:.readOnly) must throw .readOnly BEFORE acquiring the lock
    /// or performing any IO. When the file does not exist, it must remain absent.
    @Test func readOnlyUpdateThrowsReadOnlyBeforeCreatingFile() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("config")

            var caught = false
            do {
                try AWSConfigINIDocument.update(at: url, flavor: .config, mode: .readOnly) { _ in
                    Issue.record("block must never execute for read-only update")
                }
            } catch let e as AWSConfigINIError {
                if case .readOnly(let u) = e {
                    caught = true
                    #expect(u == url)
                } else {
                    Issue.record("Expected .readOnly, got: \(e)")
                }
            }
            #expect(caught, ".readOnly must be thrown by update(at:mode:.readOnly)")

            // File must not have been created (fail-fast, no IO performed).
            #expect(
                !FileManager.default.fileExists(atPath: url.path),
                "read-only update must not create the file"
            )
            // Lock file must also not have been created.
            #expect(
                !FileManager.default.fileExists(atPath: url.path + ".lock"),
                "read-only update must not create the lock file"
            )
        }
    }

    // MARK: - Custom managedHeaderText

    /// Custom `Options.managedHeaderText` is used as the header instead of the default.
    @Test func customHeaderTextIsUsed() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("config")
            let customHeader = "# Managed by AcmeCorp AutoConfig"

            var doc = AWSConfigINIDocument(empty: .config)
            doc.ensureSection("default")
            doc.update("default") { s in s.setKey("region", value: "us-west-2") }

            let opts = AWSConfigINIDocumentOptions(managedHeaderText: customHeader)
            try doc.write(to: url, mode: .managed, options: opts)

            let reloaded = try AWSConfigINIDocument(contentsOf: url)
            #expect(
                reloaded.leadingComments.first == customHeader,
                "custom header must appear as first leading comment; got: \(reloaded.leadingComments)"
            )
            // Default header must NOT be present.
            #expect(
                !reloaded.leadingComments.contains(defaultHeader),
                "default header must not appear when custom header is configured"
            )
        }
    }

    // MARK: - update(at:mode:) — managed, header idempotent on round-trip

    /// Read a managed-mode-written file with update(at:mode:.managed) and a no-op block.
    /// The header must be present exactly once in the final file — no duplication.
    @Test func managedUpdateRoundTripHeaderIdempotent() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("config")

            // First write via update.
            try AWSConfigINIDocument.update(at: url, flavor: .config, mode: .managed) { doc in
                doc.ensureSection("default")
                doc.update("default") { s in s.setKey("region", value: "us-east-2") }
            }

            // Second update (no-op mutation) — should not duplicate the header.
            try AWSConfigINIDocument.update(at: url, flavor: .config, mode: .managed) { _ in
                // intentionally empty — no mutations
            }

            let final = try AWSConfigINIDocument(contentsOf: url)
            let headerCount = final.leadingComments.filter { $0 == defaultHeader }.count
            #expect(
                headerCount == 1,
                "header must appear exactly once after round-trip update; got leading comments: \(final.leadingComments)"
            )
            // Verify the key still survives.
            #expect(final.section("default")?.key("region")?.stringValue == "us-east-2")
        }
    }

    // MARK: - ensureManagedHeader edge case not covered by integration tests

    /// Header present but NOT first → it is prepended again at position 0.
    /// (The implementation normalizes: header must always be first.)
    /// The header-absent / header-already-first / header-with-other-comments cases are
    /// covered transitively by the managedWrite* integration tests above.
    @Test func ensureHeaderNormalizesWhenPresentButNotFirst() {
        var doc = AWSConfigINIDocument(empty: .config)
        let other = "# First comment"
        doc.leadingComments = [other, defaultHeader]
        ensureManagedHeader(in: &doc, options: .default)
        // After normalization: header is first, then the two existing entries follow
        // (we only insert, we don't deduplicate — the existing one stays in place).
        #expect(doc.leadingComments[0] == defaultHeader, "header must be moved/inserted at index 0")
    }
}
