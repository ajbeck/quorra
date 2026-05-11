// WriterTests.swift — canonical writer round-trip + format-contract assertions.
//
// Decisions: D03 (canonical, not byte-exact), D14 (separator " = "),
// D15 (always double-quote), D16 ([default] first), D17 (BOM round-trip lives in BOMTests).

import Testing
import Foundation
@testable import AWSConfigINI

@Suite("Writer")
struct WriterTests {

    // MARK: - Helpers

    /// Asserts that two parsed documents are semantically equivalent: same sections, keys,
    /// values, and leading comments. Does NOT assert byte-identity (D03).
    private func assertSemanticEquivalence(
        _ a: AWSConfigINIDocument,
        _ b: AWSConfigINIDocument,
        label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(a.sections.count == b.sections.count, "\(label): section count mismatch", sourceLocation: sourceLocation)
        for (sa, sb) in zip(a.sections, b.sections) {
            #expect(sa.name == sb.name, "\(label): section name mismatch '\(sa.name)' vs '\(sb.name)'", sourceLocation: sourceLocation)
            #expect(sa.keys.count == sb.keys.count, "\(label) [\(sa.name)]: key count mismatch", sourceLocation: sourceLocation)
            for (ka, kb) in zip(sa.keys, sb.keys) {
                #expect(ka.name == kb.name, "\(label) [\(sa.name)]: key name mismatch", sourceLocation: sourceLocation)
                #expect(ka._value == kb._value, "\(label) [\(sa.name).\(ka.name)]: value mismatch", sourceLocation: sourceLocation)
                #expect(ka.leadingComments == kb.leadingComments, "\(label) [\(sa.name).\(ka.name)]: leading comments mismatch", sourceLocation: sourceLocation)
            }
            #expect(sa.leadingComments == sb.leadingComments, "\(label) [\(sa.name)]: leading comments mismatch", sourceLocation: sourceLocation)
        }
    }

    // MARK: - Round-trip parity for every fixture

    /// `parse → write → parse` must yield a semantically equivalent document for every
    /// vendored AWS-SDK fixture. Plan §9.3 DoD.
    ///
    /// `array_profile` is excluded: its stored value for `bar` contains an embedded `"`
    /// after legacyStrconv, which the writer cannot encode. Parser spec §7.4 has no
    /// escape mechanism. The encode-error path is exercised in MutationTests via setKey.
    @Test(arguments: [
        "arn_profile",
        "base_numbers_profile",
        "commented_profile",
        "comments",
        "empty_profile",
        "empty_values",
        "exponent_profile",
        "global_values_profile",
        "issue_2253",
        "issue_259",
        "mixed_case_keys",
        "nested_fields",
        "number_lhs_expr",
        "op_sep_in_values",
        "profile_name",
        "sections_profile",
        "simple_profile",
        "space_lhs",
        "utf_8_profile",
    ])
    func roundTripFixture(fixtureName: String) throws {
        let original = try AWSConfigINIDocument(loadFixtureString(fixtureName))
        let written = try original.write()
        let reparsed = try AWSConfigINIDocument(written)
        assertSemanticEquivalence(original, reparsed, label: fixtureName)
    }

    // MARK: - Empty document

    /// An empty document writes to "" — no BOM, no trailing newline. Plan §9.2.
    @Test func emptyDocumentWritesEmptyString() throws {
        #expect(try AWSConfigINIDocument(empty: .config).write() == "")
        #expect(try AWSConfigINIDocument(empty: .credentials).write() == "")
    }

    // MARK: - Sub-property maps (D12)

    /// Map-typed keys emit `name =` followed by 2-space-indented sorted entries; entry
    /// values are double-quoted (D15).
    @Test func subPropertyMapsEmitSortedDoubleQuotedEntries() throws {
        let doc = try AWSConfigINIDocument(loadFixtureString("nested_fields"))
        let written = try doc.write()
        let lines = written.components(separatedBy: "\n")

        // foo.aws_access_key_id is map-typed: parent line then sorted indented entries.
        let parentIdx = lines.firstIndex(of: "aws_access_key_id =")
        #expect(parentIdx != nil)
        if let i = parentIdx {
            #expect(lines[i + 1].hasPrefix("  aws_secret_access_key = \""))
            #expect(lines[i + 2].hasPrefix("  aws_secret_access_key2 = \""))
        }

        // bar.mp: entries a=b, b=c are sorted and double-quoted.
        let mpIdx = lines.firstIndex(of: "mp =")
        #expect(mpIdx != nil)
        if let i = mpIdx {
            #expect(lines[i + 1] == "  a = \"b\"")
            #expect(lines[i + 2] == "  b = \"c\"")
        }
    }

    // MARK: - Section ordering (D16)

    /// `[default]` is hoisted first when present; other sections keep parse order.
    @Test func defaultSectionHoistedFirst() throws {
        let doc = try AWSConfigINIDocument("[a]\nfoo = 1\n[default]\nbar = 2\n[b]\nbaz = 3\n")
        let lines = try doc.write().components(separatedBy: "\n")
        let d = lines.firstIndex(of: "[default]")!
        let a = lines.firstIndex(of: "[a]")!
        let b = lines.firstIndex(of: "[b]")!
        #expect(d < a)
        #expect(a < b)
    }

    @Test func sectionOrderPreservedWhenNoDefault() throws {
        let doc = try AWSConfigINIDocument("[c]\nk = 1\n[a]\nk = 2\n[b]\nk = 3\n")
        let lines = try doc.write().components(separatedBy: "\n")
        let c = lines.firstIndex(of: "[c]")!
        let a = lines.firstIndex(of: "[a]")!
        let b = lines.firstIndex(of: "[b]")!
        #expect(c < a)
        #expect(a < b)
    }

    // MARK: - Leading-comment preservation

    @Test func leadingCommentsRoundTrip() throws {
        let input = "# Before section\n[s]\n# before key\nk = v\n"
        let doc = try AWSConfigINIDocument(input)
        #expect(doc.section("s")?.leadingComments == ["# Before section"])
        #expect(doc.section("s")?.key("k")?.leadingComments == ["# before key"])
        let reparsed = try AWSConfigINIDocument(try doc.write())
        #expect(reparsed.section("s")?.leadingComments == ["# Before section"])
        #expect(reparsed.section("s")?.key("k")?.leadingComments == ["# before key"])
    }

    // MARK: - Section separation

    @Test func sectionsSeparatedByOneBlankLine() throws {
        let doc = try AWSConfigINIDocument("[a]\nk = 1\n[b]\nk = 2\n")
        let written = try doc.write()
        #expect(written.contains("\"1\"\n\n[b]"))
    }

    @Test func noTrailingBlankLineAfterLastSection() throws {
        let doc = try AWSConfigINIDocument("[a]\nk = 1\n")
        #expect(try doc.write().hasSuffix("\"1\"\n"))
    }

    // MARK: - write(to:)

    @Test func writeToURLProducesReadableFile() throws {
        let doc = try AWSConfigINIDocument("[default]\nregion = us-west-2\n")
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quorra_writer_\(UUID().uuidString).ini")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        try doc.write(to: tmpURL)
        let reloaded = try AWSConfigINIDocument(contentsOf: tmpURL)
        #expect(reloaded.section("default")?.key("region")?.stringValue == "us-west-2")
    }
}
