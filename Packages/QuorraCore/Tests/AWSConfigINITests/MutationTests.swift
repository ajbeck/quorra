// MutationTests.swift — tests the mutation API on Section and Document.
//
// Covers Section.setKey/deleteKey, Document.ensureSection/deleteSection/update,
// round-trip semantics for mutated documents, and the encode-error path for
// values that can't survive a write (embedded `"` or `\n`).

import Testing
import Foundation
@testable import AWSConfigINI

@Suite("Mutations")
struct MutationTests {

    // MARK: - Section.setKey(_:value:)

    @Test func setKeyUpdatesExistingStringValue() throws {
        var doc = try AWSConfigINIDocument("[s]\nregion = us-east-1\n")
        doc.update("s") { s in
            s.setKey("region", value: "eu-west-1")
        }
        #expect(doc.section("s")?.key("region")?.stringValue == "eu-west-1")
    }

    @Test func setKeyPreservesLeadingCommentsOnUpdate() throws {
        // plan §10.2 task 1: "If exists: update Value.string; preserve leadingComments."
        var doc = try AWSConfigINIDocument("[s]\n# important comment\nregion = us-east-1\n")
        doc.update("s") { s in
            s.setKey("region", value: "ap-southeast-2")
        }
        let k = doc.section("s")?.key("region")
        #expect(k?.stringValue == "ap-southeast-2")
        #expect(k?.leadingComments == ["# important comment"], "leading comments must survive a setKey update")
    }

    @Test func setKeyLowercasesName() throws {
        var doc = try AWSConfigINIDocument("[s]\n")
        doc.update("s") { s in
            s.setKey("MyKey", value: "hello")
        }
        // Must be findable as lowercase
        #expect(doc.section("s")?.key("mykey")?.stringValue == "hello")
        // Must not be findable at original case (it was never stored that way)
        #expect(doc.section("s")?.key("MyKey")?.stringValue == "hello") // key() lowercases on lookup too
        // The stored key name must be lowercase
        #expect(doc.section("s")?._keys.first?.name == "mykey")
    }

    // MARK: - Section.setKey(_:map:)

    @Test func setKeyMapUpdatesExistingMapValue() throws {
        // Start with a parsed map-typed key, overwrite the map.
        var doc = try AWSConfigINIDocument("[s]\ndynamo =\n  endpoint_url = http://old\n")
        doc.update("s") { s in
            s.setKey("dynamo", map: ["endpoint_url": "http://new"])
        }
        #expect(doc.section("s")?.key("dynamo")?.mapValue()?["endpoint_url"] == "http://new")
    }

    @Test func setKeyMapPreservesLeadingCommentsOnUpdate() throws {
        var doc = try AWSConfigINIDocument("[s]\n# service config\ndynamo =\n  endpoint_url = http://old\n")
        doc.update("s") { s in
            s.setKey("dynamo", map: ["endpoint_url": "http://new"])
        }
        #expect(doc.section("s")?.key("dynamo")?.leadingComments == ["# service config"])
    }

    @Test func setKeyMapAppendsNewMapKey() throws {
        var doc = try AWSConfigINIDocument("[s]\nregion = us-east-1\n")
        doc.update("s") { s in
            s.setKey("services", map: ["s3": "http://localhost:9000"])
        }
        let m = doc.section("s")?.key("services")?.mapValue()
        #expect(m != nil)
        #expect(m?["s3"] == "http://localhost:9000")
        // region must still be there
        #expect(doc.section("s")?.key("region")?.stringValue == "us-east-1")
    }

    // MARK: - Section.deleteKey(_:)

    @Test func deleteKeyRemovesExistingKey() throws {
        var doc = try AWSConfigINIDocument("[s]\na = 1\nb = 2\nc = 3\n")
        doc.update("s") { s in
            s.deleteKey("b")
        }
        let s = doc.section("s")!
        #expect(s.key("b") == nil)
        #expect(s.key("a")?.stringValue == "1")
        #expect(s.key("c")?.stringValue == "3")
    }

    @Test func deleteKeyIsNoOpWhenAbsent() throws {
        var doc = try AWSConfigINIDocument("[s]\na = 1\n")
        // Must not crash or change anything
        doc.update("s") { s in
            s.deleteKey("nonexistent")
        }
        #expect(doc.section("s")?.keys.count == 1)
        #expect(doc.section("s")?.key("a")?.stringValue == "1")
    }

    /// Verifies the name-index integrity (regression for the O(n) decrement path) for
    /// each position in the array: first, middle, last.
    @Test(arguments: [
        ("a", ["b", "c", "d", "e"]),  // first
        ("c", ["a", "b", "d", "e"]),  // middle
        ("e", ["a", "b", "c", "d"]),  // last
    ])
    func deleteKeyMaintainsIndexAtPosition(toDelete: String, expectedRemaining: [String]) throws {
        var doc = try AWSConfigINIDocument("[s]\na = 1\nb = 2\nc = 3\nd = 4\ne = 5\n")
        doc.update("s") { s in s.deleteKey(toDelete) }
        let s = doc.section("s")!
        #expect(s.key(toDelete) == nil)
        #expect(s.keys.map(\.name) == expectedRemaining)
        // Every remaining key must still resolve via the index after the decrement.
        for name in expectedRemaining {
            #expect(s.key(name) != nil, "key '\(name)' must still resolve after deleting '\(toDelete)'")
        }
    }

    // MARK: - Document.update(_:_:)

    @Test func updateMutatesInPlace() throws {
        // plan §10.2 task 5: in-place mutation helper
        var doc = try AWSConfigINIDocument("[profile dev]\nregion = us-east-1\n")
        // Read before
        #expect(doc.section("profile dev")?.key("region")?.stringValue == "us-east-1")
        // Mutate
        doc.update("profile dev") { s in
            s.setKey("region", value: "eu-central-1")
        }
        // Read after — must see the change on the document, not a detached copy
        #expect(doc.section("profile dev")?.key("region")?.stringValue == "eu-central-1")
    }

    @Test func updateIsNoOpWhenSectionAbsent() throws {
        var doc = try AWSConfigINIDocument("[s]\nk = v\n")
        // update on a section that doesn't exist must not create it or crash
        doc.update("nonexistent") { s in
            s.setKey("new", value: "value")
        }
        #expect(doc.section("nonexistent") == nil)
        #expect(doc.sections.count == 1)
    }

    @Test func updateDoesNotAffectOtherSections() throws {
        var doc = try AWSConfigINIDocument("[a]\nx = 1\n[b]\ny = 2\n")
        doc.update("a") { s in
            s.setKey("x", value: "99")
        }
        #expect(doc.section("a")?.key("x")?.stringValue == "99")
        #expect(doc.section("b")?.key("y")?.stringValue == "2")
    }

    // MARK: - Document.ensureSection(_:)

    @Test func ensureSectionCreatesNewSection() {
        var doc = AWSConfigINIDocument(empty: .config)
        doc.ensureSection("profile dev")
        #expect(doc.section("profile dev") != nil)
        #expect(doc.sections.count == 1)
    }

    @Test func ensureSectionIsNoOpForExisting() throws {
        var doc = try AWSConfigINIDocument("[profile dev]\nregion = us-east-1\n")
        doc.ensureSection("profile dev")
        // Section must still have its key — ensure didn't wipe it
        #expect(doc.section("profile dev")?.key("region")?.stringValue == "us-east-1")
        #expect(doc.sections.count == 1)
    }

    @Test func ensureSectionReturnValueIsSnapshot() throws {
        // Demonstrates the value-semantics caveat documented in the method:
        // mutating the returned Section does NOT update the document.
        var doc = try AWSConfigINIDocument("[s]\nk = original\n")
        var snapshot = doc.ensureSection("s")
        snapshot.setKey("k", value: "mutated")
        // The document must be unchanged — snapshot is independent
        #expect(doc.section("s")?.key("k")?.stringValue == "original",
                "ensureSection return value is a copy; mutating it must not affect the document")
    }

    @Test func ensureSectionAppendsAfterParsedSections() throws {
        // New sections appended via ensureSection must appear after parsed sections (plan §10.2 task 7, D16).
        var doc = try AWSConfigINIDocument("[existing]\nk = v\n")
        doc.ensureSection("new-section")
        let names = doc.sections.map(\.name)
        let existingIdx = names.firstIndex(of: "existing")
        let newIdx = names.firstIndex(of: "new-section")
        #expect(existingIdx != nil)
        #expect(newIdx != nil)
        if let e = existingIdx, let n = newIdx {
            #expect(e < n, "new section must be appended after existing sections")
        }
    }

    // MARK: - Document.deleteSection(_:)

    @Test func deleteSectionRemovesExistingSection() throws {
        var doc = try AWSConfigINIDocument("[a]\nk = 1\n[b]\nk = 2\n")
        doc.deleteSection("a")
        #expect(doc.section("a") == nil)
        #expect(doc.section("b") != nil)
        #expect(doc.sections.count == 1)
    }

    @Test func deleteSectionIsNoOpWhenAbsent() throws {
        var doc = try AWSConfigINIDocument("[a]\nk = 1\n")
        doc.deleteSection("nonexistent")
        #expect(doc.sections.count == 1)
        #expect(doc.section("a") != nil)
    }

    @Test func deleteThenRecreateSection() throws {
        // delete + ensureSection + update must produce a clean new section
        var doc = try AWSConfigINIDocument("[profile dev]\nregion = us-east-1\noutput = json\n")
        doc.deleteSection("profile dev")
        #expect(doc.section("profile dev") == nil)
        doc.ensureSection("profile dev")
        doc.update("profile dev") { s in
            s.setKey("region", value: "ap-southeast-1")
        }
        let s = doc.section("profile dev")!
        // Only the newly set key; the old "output" key is gone (section was deleted+recreated)
        #expect(s.key("region")?.stringValue == "ap-southeast-1")
        #expect(s.key("output") == nil, "recreated section must not carry old keys")
    }

    @Test func deleteDefaultSectionThenEnsure() throws {
        var doc = try AWSConfigINIDocument("[default]\nregion = us-east-1\n[profile dev]\nregion = eu-west-1\n")
        doc.deleteSection("default")
        #expect(doc.section("default") == nil)
        #expect(doc.sections.count == 1)
        // Re-create default and verify D16 write ordering still works
        doc.ensureSection("default")
        doc.update("default") { s in
            s.setKey("region", value: "us-west-2")
        }
        let written = try doc.write()
        let lines = written.components(separatedBy: "\n")
        let defaultLine = lines.firstIndex(of: "[default]")
        let devLine = lines.firstIndex(of: "[profile dev]")
        #expect(defaultLine != nil)
        #expect(devLine != nil)
        if let d = defaultLine, let p = devLine {
            #expect(d < p, "[default] must be written first per D16")
        }
    }

    // MARK: - parse → mutate → write → parse round-trips (plan §10.3)

    /// Round-trip pattern 1: setKey on an existing key.
    @Test func roundTripSetExistingKey() throws {
        let input = "[default]\nregion = us-east-1\noutput = json\n"
        var doc = try AWSConfigINIDocument(input)
        doc.update("default") { s in
            s.setKey("region", value: "eu-west-1")
        }
        let written = try doc.write()
        let reparsed = try AWSConfigINIDocument(written)
        let s = reparsed.section("default")!
        #expect(s.key("region")?.stringValue == "eu-west-1", "updated key must persist through write+reparse")
        #expect(s.key("output")?.stringValue == "json", "untouched key must be unchanged after round-trip")
    }

    /// Round-trip pattern 2: setKey for a new key in an existing section.
    @Test func roundTripSetNewKey() throws {
        let input = "[profile dev]\nregion = us-east-1\n"
        var doc = try AWSConfigINIDocument(input)
        doc.update("profile dev") { s in
            s.setKey("output", value: "table")
        }
        let written = try doc.write()
        let reparsed = try AWSConfigINIDocument(written)
        let s = reparsed.section("profile dev")!
        #expect(s.key("region")?.stringValue == "us-east-1")
        #expect(s.key("output")?.stringValue == "table")
    }

    /// Round-trip pattern 3: deleteSection removes a section from the written output.
    @Test func roundTripDeleteSection() throws {
        let input = "[default]\nregion = us-east-1\n[profile dev]\nregion = eu-west-1\n"
        var doc = try AWSConfigINIDocument(input)
        doc.deleteSection("profile dev")
        let written = try doc.write()
        let reparsed = try AWSConfigINIDocument(written)
        #expect(reparsed.section("default") != nil)
        #expect(reparsed.section("profile dev") == nil, "deleted section must not appear in written output")
    }

    /// Round-trip: new section added via ensureSection + update appears in the output.
    @Test func roundTripNewSectionAppended() throws {
        var doc = try AWSConfigINIDocument("[default]\nregion = us-east-1\n")
        doc.ensureSection("profile staging")
        doc.update("profile staging") { s in
            s.setKey("region", value: "ap-southeast-2")
            s.setKey("output", value: "json")
        }
        let written = try doc.write()
        let reparsed = try AWSConfigINIDocument(written)
        let s = reparsed.section("profile staging")!
        #expect(s.key("region")?.stringValue == "ap-southeast-2")
        #expect(s.key("output")?.stringValue == "json")
        // default must still be present and first
        #expect(reparsed.section("default") != nil)
        let lines = written.components(separatedBy: "\n")
        let defaultLine = lines.firstIndex(of: "[default]")
        let stagingLine = lines.firstIndex(of: "[profile staging]")
        if let d = defaultLine, let st = stagingLine {
            #expect(d < st, "[default] must precede [profile staging] per D16")
        }
    }

    /// Round-trip: map-typed key set via setKey(_:map:) encodes and re-parses correctly.
    @Test func roundTripSetMapKey() throws {
        var doc = AWSConfigINIDocument(empty: .config)
        doc.ensureSection("services local")
        doc.update("services local") { s in
            s.setKey("dynamodb", map: ["endpoint_url": "http://localhost:8000"])
        }
        let written = try doc.write()
        let reparsed = try AWSConfigINIDocument(written)
        let m = reparsed.section("services local")?.key("dynamodb")?.mapValue()
        #expect(m != nil)
        #expect(m?["endpoint_url"] == "http://localhost:8000")
    }

    // MARK: - Key insertion order

    /// Adding a new key to an existing section preserves the other keys' order; the new
    /// key is appended at the end. Implicitly also covers the "untouched keys unchanged"
    /// mutation-locality property.
    @Test func newKeyPreservesExistingKeyOrder() throws {
        let input = "[s]\nfirst = 1\nsecond = 2\nthird = 3\n"
        var doc = try AWSConfigINIDocument(input)
        doc.update("s") { s in
            s.setKey("fourth", value: "4")
        }
        let s = doc.section("s")!
        let names = s.keys.map(\.name)
        #expect(names == ["first", "second", "third", "fourth"],
                "new key must be appended; existing order must be preserved")
    }

    // MARK: - encodeError for injected " and \n (plan §9.3 DoD last bullet; D22)

    /// Reachable from M04 mutation but not from parsing (parser spec §7.4 strips outer quotes;
    /// §3.2 splits on `\n`). Plan §9.3 DoD last bullet; Decision D22.
    @Test(arguments: [
        ("contains\"quote", "embedded double-quote"),
        ("line1\nline2",    "embedded newline"),
    ])
    func encodeErrorForUnrepresentableValue(value: String, description: String) throws {
        var doc = AWSConfigINIDocument(empty: .config)
        doc.ensureSection("s")
        doc.update("s") { s in
            s.setKey("bad", value: value)
        }
        let thrown = #expect(throws: AWSConfigINIError.self, "\(description) must throw") {
            _ = try doc.write()
        }
        guard case .encodeError = thrown else {
            Issue.record("Expected .encodeError, got: \(String(describing: thrown))")
            return
        }
    }

    // MARK: - Section order (D16) after mutations

    /// New sections appended after all parsed sections; [default] still hoisted first on write.
    @Test func newSectionsAppendedInInsertionOrderAfterD16Hoist() throws {
        var doc = try AWSConfigINIDocument("[profile a]\nk = 1\n[profile b]\nk = 2\n")
        doc.ensureSection("default")
        doc.update("default") { s in s.setKey("region", value: "us-east-1") }
        doc.ensureSection("profile c")
        doc.update("profile c") { s in s.setKey("k", value: "3") }

        let written = try doc.write()
        let lines = written.components(separatedBy: "\n")
        let defaultLine = lines.firstIndex(of: "[default]")
        let aLine = lines.firstIndex(of: "[profile a]")
        let bLine = lines.firstIndex(of: "[profile b]")
        let cLine = lines.firstIndex(of: "[profile c]")
        #expect(defaultLine != nil)
        #expect(aLine != nil)
        #expect(bLine != nil)
        #expect(cLine != nil)
        if let d = defaultLine, let a = aLine, let b = bLine, let c = cLine {
            // [default] hoisted first (D16)
            #expect(d < a, "[default] must precede [profile a]")
            #expect(d < b, "[default] must precede [profile b]")
            // Parsed order preserved for a, b
            #expect(a < b, "[profile a] must precede [profile b] (parse order)")
            // New section appended last
            #expect(b < c, "[profile b] must precede newly-appended [profile c]")
        }
    }
}
