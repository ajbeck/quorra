// ParsingTests.swift — exercises the parser against the AWS-SDK fixture corpus,
// hand-written realistic AWS configs, and the parser's documented edge cases:
// orphan promotion, continuation handling, and warning emission.

import Testing
import Foundation
@testable import AWSConfigINI

// MARK: - AWS-SDK fixture parity (parameterized round-trip against expected JSON)

@Suite("Parsing — AWS-SDK fixtures")
struct AWSSDKFixtureTests {

    /// Vendored fixtures under Tests/.../Resources/aws-sdk-fixtures/. Each fixture has a
    /// matching `<name>_expected` JSON file the parser's output must satisfy. The expected
    /// JSON is "loose" (parser spec §14): it may omit some keys the parser stores. We only
    /// assert what's listed.
    @Test(arguments: [
        "arn_profile",
        "base_numbers_profile",
        "commented_profile",
        "comments",
        "exponent_profile",
        "issue_2253",
        "issue_259",
        "mixed_case_keys",
        "nested_fields",
        "number_lhs_expr",
        "op_sep_in_values",
        "profile_name",
        "sections_profile",
        "simple_profile",
    ])
    func fixtureMatchesExpectedJSON(_ name: String) throws {
        let doc = try AWSConfigINIDocument(loadFixtureString(name))
        assertMatchesExpected(document: doc, expected: loadExpected(name), fixture: name)
    }

    /// Fixtures with parser-spec quirks worth asserting beyond the loose `_expected` JSON.

    @Test func arrayProfileQuoteStripping() throws {
        // Parser spec §9.4: array_profile's `bar` value contains an embedded `"` after
        // legacyStrconv strips a single outer pair from `"one","two", "three"`.
        let doc = try AWSConfigINIDocument(loadFixtureString("array_profile"))
        assertMatchesExpected(document: doc, expected: loadExpected("array_profile"), fixture: "array_profile")
        let foo = doc.section("foo")
        #expect(foo?.key("qux")?.mapValue() != nil)
        #expect(foo?.key("bar")?.stringValue == #"one","two", "three"#)
    }

    @Test func emptyProfileSectionHasNoKeys() throws {
        let doc = try AWSConfigINIDocument(loadFixtureString("empty_profile"))
        assertMatchesExpected(document: doc, expected: loadExpected("empty_profile"), fixture: "empty_profile")
        let def = doc.section("default")
        #expect(def != nil)
        #expect(def?.keys.isEmpty == true)
    }

    @Test func emptyValuesStoresEmptyStrings() throws {
        // The expected JSON for foo is {} but the parser stores empty-string values.
        let doc = try AWSConfigINIDocument(loadFixtureString("empty_values"))
        assertMatchesExpected(document: doc, expected: loadExpected("empty_values"), fixture: "empty_values")
        #expect(doc.section("foo")?.key("aws_access_key_id")?.stringValue == "")
    }

    @Test func globalValuesProfileDropsPreSectionPropertyAndWarns() throws {
        let doc = try AWSConfigINIDocument(loadFixtureString("global_values_profile"))
        assertMatchesExpected(document: doc, expected: loadExpected("global_values_profile"), fixture: "global_values_profile")
        #expect(doc.sections.count == 1)
        #expect(doc.sections.first?.name == "default")
        #expect(!doc.globalWarnings.isEmpty)
    }

    @Test func mixedCaseKeysAreLowercasedOnStore() throws {
        let doc = try AWSConfigINIDocument(loadFixtureString("mixed_case_keys"))
        assertMatchesExpected(document: doc, expected: loadExpected("mixed_case_keys"), fixture: "mixed_case_keys")
        let section = doc.section("with_mixed_case_keys")
        #expect(section?._keys.first(where: { $0.name == "string_value" }) != nil)
        #expect(section?._keys.first(where: { $0.name == "sTring_Value" }) == nil)
    }

    @Test func profileNamePreservesTypePrefixInSectionName() throws {
        let doc = try AWSConfigINIDocument(loadFixtureString("profile_name"))
        assertMatchesExpected(document: doc, expected: loadExpected("profile_name"), fixture: "profile_name")
        #expect(doc.section("profile foo") != nil)
    }

    @Test func spaceLhsAllowsSpacesInKeyNames() throws {
        let doc = try AWSConfigINIDocument(loadFixtureString("space_lhs"))
        assertMatchesExpected(document: doc, expected: loadExpected("space_lhs"), fixture: "space_lhs")
        #expect(doc.section("hyphen-profile-name")?.key("aws region") != nil)
    }

    @Test func utf8ProfilePreservesAndLowercasesNonASCII() throws {
        let doc = try AWSConfigINIDocument(loadFixtureString("utf_8_profile"))
        assertMatchesExpected(document: doc, expected: loadExpected("utf_8_profile"), fixture: "utf_8_profile")
        let section = doc.section("ʃʉʍΡιξ")
        #expect(section != nil)
        // ϰϪϧ → ϰϫϧ (Unicode lowercasing of a Greek capital)
        #expect(section?.key("ϰϫϧ") != nil)
        #expect(section?.key("ϝϧ")?.stringValue == "ϟΞ΅")
    }
}

// MARK: - Realistic hand-written AWS configs

@Suite("Parsing — realistic AWS configs")
struct RealisticConfigTests {

    private func realisticURL(_ name: String) -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources/realistic") else {
            fatalError("Missing realistic fixture: \(name)")
        }
        return url
    }

    @Test func typicalConfig() throws {
        let doc = try AWSConfigINIDocument(contentsOf: realisticURL("typical_config"))
        #expect(doc.section("default") != nil)
        #expect(doc.section("profile dev") != nil)
        #expect(doc.section("sso-session my-company-sso") != nil)
        #expect(doc.section("profile dev")?.key("sso_session")?.stringValue == "my-company-sso")
    }

    @Test func credentialsOnly() throws {
        let doc = try AWSConfigINIDocument(contentsOf: realisticURL("credentials_only"), flavor: .credentials)
        #expect(doc.flavor == .credentials)
        #expect(doc.section("default") != nil)
        #expect(doc.section("dev") != nil)
        #expect(doc.section("default")?.key("aws_access_key_id")?.stringValue == "AKIAIOSFODNN7EXAMPLE")
    }

    @Test func servicesSection() throws {
        let doc = try AWSConfigINIDocument(contentsOf: realisticURL("services_section"))
        let services = doc.section("services local-overrides")
        #expect(services?.key("dynamodb")?.mapValue()?["endpoint_url"] == "http://localhost:8000")
        #expect(services?.key("s3")?.mapValue()?["endpoint_url"] == "http://localhost:9000")
    }

    @Test func emptyFile() throws {
        let doc = try AWSConfigINIDocument(contentsOf: realisticURL("empty_file"))
        #expect(doc.sections.isEmpty)
    }

    @Test func commentOnly() throws {
        let doc = try AWSConfigINIDocument(contentsOf: realisticURL("comment_only"))
        #expect(doc.sections.isEmpty)
    }

    @Test func hyphenatedProfiles() throws {
        let doc = try AWSConfigINIDocument(contentsOf: realisticURL("hyphenated_profiles"))
        #expect(doc.section("profile my-org-dev-us-east-1") != nil)
        #expect(doc.section("profile my-org-prod-eu-west-1")?.key("source_profile")?.stringValue == "default")
    }
}

// MARK: - Orphan promotion (parser spec §9.2)

@Suite("Parsing — orphan promotion")
struct OrphanPromotionTests {

    /// Walks parser spec §9.2 manually against the nested_fields fixture: the rule is
    /// that an indented k=v whose parent has a non-empty string value is promoted to a
    /// top-level property; an indented k=v under an empty parent attaches as a sub-property.
    @Test func nestedFieldsExercisesEveryBranch() throws {
        let doc = try AWSConfigINIDocument(loadFixtureString("nested_fields"))

        // foo: aws_access_key_id is a map (parent had empty value, sub-properties attached)
        let fooKeyId = doc.section("foo")?.key("aws_access_key_id")
        let fooMap = fooKeyId?.mapValue()
        #expect(fooMap?["aws_secret_access_key"] == "valid;comment")
        #expect(fooMap?["aws_secret_access_key2"] == "valid2")

        // bar: orphan-promoted lines lose comments; mp is a map
        let bar = doc.section("bar")
        #expect(bar?.key("aws_access_key_id")?.stringValue == "valid")
        #expect(bar?.key("aws_secret_access_key")?.stringValue == "valid")
        #expect(bar?.key("not_nested")?.stringValue == "i")
        let mp = bar?.key("mp")?.mapValue()
        #expect(mp?["a"] == "b")
        #expect(mp?["b"] == "c")

        // baz: first orphan-promoted line; second attaches as sub-property
        let bazMap = doc.section("baz")?.key("aws_access_key_id")?.mapValue()
        #expect(bazMap?["aws_secret_access_key"] == "valid")
    }

    /// Indented `[bar]` is a top-level section, not nested under the previous section.
    @Test func indentedSectionBecomesTopLevel() throws {
        let doc = try AWSConfigINIDocument(loadFixtureString("nested_fields"))
        #expect(doc.section("bar") != nil)
        let names = doc.sections.map { $0.name }
        #expect(names.contains("foo"))
        #expect(names.contains("bar"))
        #expect(names.contains("baz"))
    }
}

// MARK: - Continuations (parser spec §9.3)

@Suite("Parsing — continuations")
struct ContinuationTests {

    @Test func continuationAppendsToNonEmptyString() throws {
        let doc = try AWSConfigINIDocument("[s]\nkey = first line\n  continuation here\n")
        #expect(doc.section("s")?.key("key")?.stringValue == "first line\ncontinuation here")
    }

    @Test func continuationDroppedForEmptyParent() throws {
        let doc = try AWSConfigINIDocument("[s]\nkey =\n  continuation here\n")
        #expect(doc.section("s")?.key("key")?.stringValue == "")
    }

    @Test func continuationDroppedForMapParent() throws {
        let doc = try AWSConfigINIDocument("[s]\nkey =\n  sub = value\n  continuation without separator\n")
        #expect(doc.section("s")?.key("key")?.mapValue() != nil)
    }
}

// MARK: - Warning collection

@Suite("Parsing — warnings")
struct WarningTests {

    @Test func duplicateKeyOverwritesAndWarns() throws {
        let doc = try AWSConfigINIDocument("[section]\nfoo = first\nfoo = second\n")
        let section = doc.section("section")
        #expect(section?.key("foo")?.stringValue == "second")
        let dupeWarnings = section?.warnings.filter {
            if case .duplicateKey(let name) = $0.kind { return name == "foo" }
            return false
        }
        #expect(dupeWarnings?.isEmpty == false)
    }

    @Test func propertyBeforeSectionDropsAndWarns() throws {
        let doc = try AWSConfigINIDocument("orphan = value\n[section]\nfoo = bar\n")
        #expect(doc.sections.count == 1)
        #expect(doc.sections.first?.name == "section")
        let presectionWarnings = doc.globalWarnings.filter {
            if case .propertyBeforeSection = $0.kind { return true }
            return false
        }
        #expect(!presectionWarnings.isEmpty)
    }
}
