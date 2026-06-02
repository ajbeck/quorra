// CodableTests.swift — Codable encoder/decoder + AWS overlay (Profile, SSOSession,
// ServicesEntry, decodeProfile/encodeProfile convenience methods, FileFlavor projection).

import Testing
import Foundation
@testable import AWSConfigINI

// MARK: - Test fixtures

struct TestProfile: Codable, Equatable {
    var region: String?
    var output: String?
    var ssoSession: String?

    enum CodingKeys: String, CodingKey {
        case region
        case output
        case ssoSession = "ssoSession"
        // With KeyDecodingStrategy.convertFromSnakeCase active, the INI key
        // "sso_session" is converted to "ssoSession" before matching CodingKeys.
    }
}

/// Required (non-Optional) field — used to test missing-key error path.
struct RequiredFieldProfile: Codable {
    var region: String
    var output: String?
}

struct IntProfile: Codable {
    var port: Int
}

struct BoolProfile: Codable {
    var enabled: Bool
    var verbose: Bool?
}

struct SSOProfile: Codable, Equatable {
    var ssoRegistrationScopes: [String]?

    enum CodingKeys: String, CodingKey {
        case ssoRegistrationScopes = "ssoRegistrationScopes"
    }
}

/// Used to verify nested-struct rejection.
struct NestedProfile: Codable {
    var region: String?
    var nested: RequiredFieldProfile?
}

// MARK: - Helpers

private func realisticURL(_ name: String) -> URL {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources/realistic") else {
        fatalError("Missing realistic fixture: \(name)")
    }
    return url
}

// MARK: - Codable: decode / encode core

@Suite("Codable")
struct CodableTests {

    // MARK: - Basic decode / encode round-trip

    @Test func decodeFromTypicalConfig() throws {
        let doc = try AWSConfigINIDocument(contentsOf: realisticURL("typical_config"))
        let decoder = AWSConfigINIDecoder()
        let defaultProfile = try decoder.decode(TestProfile.self, from: doc, section: "default")
        #expect(defaultProfile.region == "us-east-1")
        #expect(defaultProfile.output == "json")
        #expect(defaultProfile.ssoSession == nil)

        // The dev profile has sso_session — convertFromSnakeCase maps it to ssoSession.
        let dev = try decoder.decode(TestProfile.self, from: doc, section: "profile dev")
        #expect(dev.ssoSession == "my-company-sso")
    }

    @Test func encodeWriteReparseDecodeRoundTrip() throws {
        var doc = AWSConfigINIDocument(empty: .config)
        let encoder = AWSConfigINIEncoder()
        let original = TestProfile(region: "eu-central-1", output: "table", ssoSession: "my-sso")
        try encoder.encode(original, into: &doc, section: "profile dev")

        // Verify the raw INI key uses snake_case.
        let reparsed = try AWSConfigINIDocument(try doc.write())
        #expect(reparsed.section("profile dev")?.key("sso_session")?.stringValue == "my-sso")

        let decoded = try AWSConfigINIDecoder().decode(TestProfile.self, from: reparsed, section: "profile dev")
        #expect(decoded == original)
    }

    @Test func encodeIntoNewSectionCreatesSection() throws {
        var doc = AWSConfigINIDocument(empty: .config)
        try AWSConfigINIEncoder().encode(
            TestProfile(region: "ap-southeast-1", output: nil, ssoSession: nil),
            into: &doc,
            section: "profile new"
        )
        #expect(doc.section("profile new")?.key("region")?.stringValue == "ap-southeast-1")
    }

    // MARK: - Decode errors

    @Test func missingSectionThrowsDecodeError() throws {
        let doc = AWSConfigINIDocument(empty: .config)
        let thrown = #expect(throws: AWSConfigINIError.self) {
            _ = try AWSConfigINIDecoder().decode(TestProfile.self, from: doc, section: "nonexistent")
        }
        guard case .decodeError(let msg) = thrown else {
            Issue.record("Expected .decodeError, got: \(String(describing: thrown))"); return
        }
        #expect(msg.contains("nonexistent"))
    }

    @Test func missingRequiredFieldThrowsDecodeError() throws {
        let doc = try AWSConfigINIDocument("[default]\noutput = json\n")
        let thrown = #expect(throws: AWSConfigINIError.self) {
            _ = try AWSConfigINIDecoder().decode(RequiredFieldProfile.self, from: doc, section: "default")
        }
        guard case .decodeError(let msg) = thrown else {
            Issue.record("Expected .decodeError, got: \(String(describing: thrown))"); return
        }
        #expect(msg.contains("region"))
    }

    @Test func typeMismatchThrowsDecodeError() throws {
        let doc = try AWSConfigINIDocument("[default]\nport = not-a-number\n")
        let thrown = #expect(throws: AWSConfigINIError.self) {
            _ = try AWSConfigINIDecoder().decode(IntProfile.self, from: doc, section: "default")
        }
        guard case .decodeError(let msg) = thrown else {
            Issue.record("Expected .decodeError, got: \(String(describing: thrown))"); return
        }
        #expect(msg.contains("port"))
    }

    // MARK: - Boolean leniency (D11)

    @Test func boolStrictAcceptsTrueFalseRejectsYes() throws {
        let doc = try AWSConfigINIDocument("[default]\nenabled = true\nverbose = FALSE\n")
        let decoded = try AWSConfigINIDecoder().decode(BoolProfile.self, from: doc, section: "default")
        #expect(decoded.enabled == true)
        #expect(decoded.verbose == false)

        // Strict rejects "yes" with a clear error.
        let yesDoc = try AWSConfigINIDocument("[default]\nenabled = yes\n")
        let thrown = #expect(throws: AWSConfigINIError.self) {
            _ = try AWSConfigINIDecoder().decode(BoolProfile.self, from: yesDoc, section: "default")
        }
        guard case .decodeError(let msg) = thrown else {
            Issue.record("Expected .decodeError, got: \(String(describing: thrown))"); return
        }
        #expect(msg.contains("enabled"))
    }

    @Test(arguments: ["yes", "on", "1", "YES", "On", "Y"])
    func boolLenientAcceptsTrueVariants(input: String) throws {
        let doc = try AWSConfigINIDocument("[default]\nenabled = \(input)\n")
        var decoder = AWSConfigINIDecoder()
        decoder.booleanLeniency = .lenient
        #expect(try decoder.decode(BoolProfile.self, from: doc, section: "default").enabled == true)
    }

    @Test(arguments: ["no", "off", "0", "NO", "Off", "N"])
    func boolLenientAcceptsFalseVariants(input: String) throws {
        let doc = try AWSConfigINIDocument("[default]\nenabled = \(input)\n")
        var decoder = AWSConfigINIDecoder()
        decoder.booleanLeniency = .lenient
        #expect(try decoder.decode(BoolProfile.self, from: doc, section: "default").enabled == false)
    }

    /// Encode emits strict form regardless of leniency setting (D11).
    @Test func boolEncodeAlwaysStrictForm() throws {
        struct BoolContainer: Codable { var enabled: Bool; var verbose: Bool }
        var doc = AWSConfigINIDocument(empty: .config)
        var encoder = AWSConfigINIEncoder()
        encoder.keyEncodingStrategy = .useDefaultKeys
        try encoder.encode(BoolContainer(enabled: true, verbose: false), into: &doc, section: "s")
        #expect(doc.section("s")?.key("enabled")?.stringValue == "true")
        #expect(doc.section("s")?.key("verbose")?.stringValue == "false")
    }

    // MARK: - omitEmpty

    @Test func omitEmptyTrueDropsNilFields() throws {
        var doc = AWSConfigINIDocument(empty: .config)
        try AWSConfigINIEncoder().encode(
            TestProfile(region: "us-east-1", output: nil, ssoSession: nil),
            into: &doc,
            section: "default"
        )
        let s = doc.section("default")!
        #expect(s.key("region")?.stringValue == "us-east-1")
        #expect(s.key("output") == nil)
        #expect(s.key("sso_session") == nil)
    }

    /// Synthesized Codable uses encodeIfPresent for Optional fields, so omitEmpty=false only
    /// affects structs that explicitly call `container.encodeNil(forKey:)`.
    @Test func omitEmptyFalseExplicitNilProducesEmptyKey() throws {
        struct ExplicitNil: Encodable {
            var region: String
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(region, forKey: .region)
                try c.encodeNil(forKey: .output)
            }
            enum CodingKeys: String, CodingKey { case region, output }
        }
        var doc = AWSConfigINIDocument(empty: .config)
        var encoder = AWSConfigINIEncoder()
        encoder.omitEmpty = false
        encoder.keyEncodingStrategy = .useDefaultKeys
        try encoder.encode(ExplicitNil(region: "us-east-1"), into: &doc, section: "default")
        #expect(doc.section("default")?.key("output")?.stringValue == "")
    }

    // MARK: - Snake-case strategy (unit-level)

    @Test func camelToSnakeConversion() {
        #expect(camelToSnake("ssoSession") == "sso_session")
        #expect(camelToSnake("credentialProcess") == "credential_process")
        #expect(camelToSnake("region") == "region")
        #expect(camelToSnake("roleARN") == "role_arn")
        #expect(camelToSnake("ssoRegistrationScopes") == "sso_registration_scopes")
        #expect(camelToSnake("") == "")
    }

    @Test func snakeToCamelConversion() {
        #expect(snakeToCamel("sso_session") == "ssoSession")
        #expect(snakeToCamel("credential_process") == "credentialProcess")
        #expect(snakeToCamel("region") == "region")
        #expect(snakeToCamel("sso_registration_scopes") == "ssoRegistrationScopes")
        #expect(snakeToCamel("") == "")
    }

    // MARK: - Sub-property maps

    @Test func subPropertyMapRoundTrip() throws {
        struct ServiceEndpoints: Codable {
            var dynamodb: [String: String]?
            var s3: [String: String]?
        }

        // Decode from the realistic services_section fixture.
        let doc = try AWSConfigINIDocument(contentsOf: realisticURL("services_section"))
        var decoder = AWSConfigINIDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        let decoded = try decoder.decode(ServiceEndpoints.self, from: doc, section: "services local-overrides")
        #expect(decoded.dynamodb?["endpoint_url"] == "http://localhost:8000")
        #expect(decoded.s3?["endpoint_url"] == "http://localhost:9000")

        // Re-encode + reparse + redecode.
        var roundTripDoc = AWSConfigINIDocument(empty: .config)
        var encoder = AWSConfigINIEncoder()
        encoder.keyEncodingStrategy = .useDefaultKeys
        try encoder.encode(decoded, into: &roundTripDoc, section: "services test")
        #expect(roundTripDoc.section("services test")?.key("dynamodb")?.mapValue()?["endpoint_url"] == "http://localhost:8000")
        let reparsed = try AWSConfigINIDocument(try roundTripDoc.write())
        let again = try decoder.decode(ServiceEndpoints.self, from: reparsed, section: "services test")
        #expect(again.dynamodb?["endpoint_url"] == "http://localhost:8000")
    }

    // MARK: - [String] comma-separated lists

    @Test func commaListRoundTrip() throws {
        let doc = try AWSConfigINIDocument(
            "[sso-session my-sso]\nsso_registration_scopes = sso:account:access, sso:role:read\n"
        )
        let decoded = try AWSConfigINIDecoder().decode(SSOProfile.self, from: doc, section: "sso-session my-sso")
        #expect(decoded.ssoRegistrationScopes == ["sso:account:access", "sso:role:read"])

        // Re-encode and verify the joined raw value.
        var roundTripDoc = AWSConfigINIDocument(empty: .config)
        try AWSConfigINIEncoder().encode(decoded, into: &roundTripDoc, section: "sso-session my-sso")
        let raw = roundTripDoc.section("sso-session my-sso")?.key("sso_registration_scopes")?.stringValue
        #expect(raw == "sso:account:access, sso:role:read")
    }

    // MARK: - Nested struct rejection (M07-style; still rejected at the Codable layer)

    @Test func nestedDecodableStructRejected() throws {
        let doc = try AWSConfigINIDocument("[default]\nregion = us-east-1\nnested = something\n")
        let thrown = #expect(throws: AWSConfigINIError.self) {
            _ = try AWSConfigINIDecoder().decode(NestedProfile.self, from: doc, section: "default")
        }
        if case .decodeError = thrown { /* ok */ } else {
            Issue.record("Expected .decodeError for nested struct, got: \(String(describing: thrown))")
        }
    }

    @Test func nestedEncodableStructRejected() throws {
        var doc = AWSConfigINIDocument(empty: .config)
        let thrown = #expect(throws: AWSConfigINIError.self) {
            _ = try AWSConfigINIEncoder().encode(
                NestedProfile(region: "us-east-1", nested: RequiredFieldProfile(region: "eu-west-1", output: nil)),
                into: &doc,
                section: "default"
            )
        }
        if case .encodeError = thrown { /* ok */ } else {
            Issue.record("Expected .encodeError for nested struct, got: \(String(describing: thrown))")
        }
    }

    // MARK: - Section-replace semantics + comment preservation

    @Test func sectionReplaceDropsExtraKeysAndPreservesLeadingComments() throws {
        // Section already exists with leading comments and extra keys.
        let input = "# This is the default profile\n[default]\nregion = us-east-1\noutput = json\nextra_key = should-be-removed\n"
        var doc = try AWSConfigINIDocument(input)
        try AWSConfigINIEncoder().encode(
            TestProfile(region: "eu-west-1", output: "yaml", ssoSession: nil),
            into: &doc,
            section: "default"
        )
        let s = doc.section("default")!
        #expect(s.key("region")?.stringValue == "eu-west-1")
        #expect(s.key("output")?.stringValue == "yaml")
        #expect(s.key("extra_key") == nil, "section-replace must drop unrelated keys")
        #expect(s.leadingComments == ["# This is the default profile"], "section comments must survive encode")
    }

    // MARK: - Optional present / absent

    @Test func optionalPresentAndAbsentDecodeCorrectly() throws {
        let docWith = try AWSConfigINIDocument("[default]\noutput = json\n")
        #expect(try AWSConfigINIDecoder().decode(TestProfile.self, from: docWith, section: "default").output == "json")

        let docWithout = try AWSConfigINIDocument("[default]\nregion = us-east-1\n")
        let decoded = try AWSConfigINIDecoder().decode(TestProfile.self, from: docWithout, section: "default")
        #expect(decoded.output == nil)
        #expect(decoded.ssoSession == nil)
    }
}

// MARK: - AWS overlay: FileFlavor projection + Profile / SSOSession / ServicesEntry

@Suite("Codable — AWS overlay")
struct AWSOverlayTests {

    // MARK: FileFlavor.profileSectionName(for:)

    @Test(arguments: [
        (FileFlavor.config,      "default", "default"),
        (FileFlavor.config,      "dev",     "profile dev"),
        (FileFlavor.credentials, "default", "default"),
        (FileFlavor.credentials, "dev",     "dev"),
        (FileFlavor.config,      "my-work-profile", "profile my-work-profile"),
        (FileFlavor.credentials, "my-work-profile", "my-work-profile"),
    ] as [(FileFlavor, String, String)])
    func profileSectionNameMatrix(flavor: FileFlavor, profileName: String, expectedSection: String) {
        #expect(flavor.profileSectionName(for: profileName) == expectedSection)
    }

    // MARK: Document.profileSection(named:)

    @Test func documentProfileSectionResolution() throws {
        let configDoc = try AWSConfigINIDocument(
            "[default]\nregion = us-east-1\n\n[profile dev]\nregion = eu-west-1\n",
            flavor: .config
        )
        #expect(configDoc.profileSection(named: "default")?.key("region")?.stringValue == "us-east-1")
        #expect(configDoc.profileSection(named: "dev")?.key("region")?.stringValue == "eu-west-1")
        #expect(configDoc.profileSection(named: "nonexistent") == nil)

        let credDoc = try AWSConfigINIDocument(
            "[default]\nregion = us-east-1\n\n[dev]\nregion = eu-west-1\n",
            flavor: .credentials
        )
        #expect(credDoc.profileSection(named: "dev")?.key("region")?.stringValue == "eu-west-1")
    }

    // MARK: encodeProfile / decodeProfile flavor projection

    @Test func encodeProfileUsesFlavorProjection() throws {
        let profile = Profile(region: "us-east-1", output: "json")

        var configDoc = AWSConfigINIDocument(empty: .config)
        try AWSConfigINIEncoder().encodeProfile(profile, named: "foo", into: &configDoc)
        #expect(configDoc.section("profile foo") != nil)
        #expect(configDoc.section("foo") == nil)

        var credDoc = AWSConfigINIDocument(empty: .credentials)
        try AWSConfigINIEncoder().encodeProfile(profile, named: "foo", into: &credDoc)
        #expect(credDoc.section("foo") != nil)
        #expect(credDoc.section("profile foo") == nil)
    }

    @Test func encodeProfileNamedDefaultIgnoresFlavor() throws {
        var configDoc = AWSConfigINIDocument(empty: .config)
        var credDoc = AWSConfigINIDocument(empty: .credentials)
        let profile = Profile(region: "us-east-1")
        try AWSConfigINIEncoder().encodeProfile(profile, named: "default", into: &configDoc)
        try AWSConfigINIEncoder().encodeProfile(profile, named: "default", into: &credDoc)
        #expect(configDoc.section("default") != nil)
        #expect(credDoc.section("default") != nil)
        #expect(configDoc.section("profile default") == nil)
    }

    @Test func decodeProfileFlavorProjection() throws {
        let configIni = "[profile dev]\nregion = eu-west-1\nsso_session = my-sso\ncredential_process = /usr/local/bin/aws-credential-helper --profile dev\n"
        let configDoc = try AWSConfigINIDocument(configIni, flavor: .config)
        let dev = try AWSConfigINIDecoder().decodeProfile(Profile.self, named: "dev", from: configDoc)
        #expect(dev.region == "eu-west-1")
        #expect(dev.ssoSession == "my-sso")
        #expect(dev.credentialProcess == "/usr/local/bin/aws-credential-helper --profile dev")

        let credIni = "[prod]\nregion = us-west-2\nsource_profile = default\nrole_arn = arn:aws:iam::123456789012:role/MyRole\n"
        let credDoc = try AWSConfigINIDocument(credIni, flavor: .credentials)
        let prod = try AWSConfigINIDecoder().decodeProfile(Profile.self, named: "prod", from: credDoc)
        #expect(prod.sourceProfile == "default")
        #expect(prod.roleArn == "arn:aws:iam::123456789012:role/MyRole")
    }

    @Test func profileFullRoundTrip() throws {
        var doc = AWSConfigINIDocument(empty: .config)
        let original = Profile(
            region: "us-east-1",
            output: "json",
            ssoSession: "corp-sso",
            credentialProcess: nil,
            sourceProfile: nil,
            roleArn: nil,
            roleSessionName: "my-session",
            mfaSerial: nil
        )
        try AWSConfigINIEncoder().encodeProfile(original, named: "dev", into: &doc)
        let reparsed = try AWSConfigINIDocument(try doc.write(), flavor: .config)
        let decoded = try AWSConfigINIDecoder().decodeProfile(Profile.self, named: "dev", from: reparsed)
        #expect(decoded == original)
    }

    // MARK: SSOSession with sso_registration_scopes (comma-separated [String])

    @Test func ssoSessionRoundTripWithMultipleScopes() throws {
        var doc = AWSConfigINIDocument(empty: .config)
        let original = SSOSession(
            ssoStartUrl: "https://example.awsapps.com/start",
            ssoRegion: "us-east-1",
            ssoRegistrationScopes: ["sso:account:access", "sso:role:read"]
        )
        try AWSConfigINIEncoder().encode(original, into: &doc, section: "sso-session corp-sso")
        let s = doc.section("sso-session corp-sso")!
        #expect(s.key("sso_registration_scopes")?.stringValue == "sso:account:access, sso:role:read")

        let reparsed = try AWSConfigINIDocument(try doc.write(), flavor: .config)
        let decoded = try AWSConfigINIDecoder().decode(SSOSession.self, from: reparsed, section: "sso-session corp-sso")
        #expect(decoded == original)
    }

    @Test func ssoSessionNilScopesOmitsKey() throws {
        var doc = AWSConfigINIDocument(empty: .config)
        let original = SSOSession(ssoStartUrl: "https://example.com", ssoRegion: "eu-west-1", ssoRegistrationScopes: nil)
        try AWSConfigINIEncoder().encode(original, into: &doc, section: "sso-session test")
        #expect(doc.section("sso-session test")?.key("sso_registration_scopes") == nil)
    }

    // MARK: ServicesEntry — two-layer custom Codable

    @Test func servicesEntryDecodeFromFixture() throws {
        let url = Bundle.module.url(forResource: "services_section", withExtension: nil, subdirectory: "Resources/realistic")!
        let doc = try AWSConfigINIDocument(contentsOf: url, flavor: .config)
        var decoder = AWSConfigINIDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        let entry = try decoder.decode(ServicesEntry.self, from: doc, section: "services local-overrides")
        #expect(entry.entries["dynamodb"]?["endpoint_url"] == "http://localhost:8000")
        #expect(entry.entries["s3"]?["endpoint_url"] == "http://localhost:9000")
        #expect(entry.entries["sqs"]?["endpoint_url"] == "http://localhost:9324")
        #expect(entry.entries.count == 3)
    }

    @Test func servicesEntryEncodeRoundTrip() throws {
        let original = ServicesEntry(entries: [
            "dynamodb": ["endpoint_url": "http://localhost:1234"],
            "s3":       ["endpoint_url": "http://localhost:5678"],
        ])
        var doc = AWSConfigINIDocument(empty: .config)
        var encoder = AWSConfigINIEncoder()
        encoder.keyEncodingStrategy = .useDefaultKeys
        try encoder.encode(original, into: &doc, section: "services my-services")

        let s = doc.section("services my-services")!
        #expect(s.key("dynamodb")?.mapValue()?["endpoint_url"] == "http://localhost:1234")
        #expect(s.key("s3")?.mapValue()?["endpoint_url"] == "http://localhost:5678")

        let reparsed = try AWSConfigINIDocument(try doc.write(), flavor: .config)
        var decoder = AWSConfigINIDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        let decoded = try decoder.decode(ServicesEntry.self, from: reparsed, section: "services my-services")
        #expect(decoded.entries["dynamodb"]?["endpoint_url"] == "http://localhost:1234")
        #expect(decoded.entries["s3"]?["endpoint_url"] == "http://localhost:5678")
    }

    @Test func servicesEntryEmptyRoundTrip() throws {
        var doc = AWSConfigINIDocument(empty: .config)
        var encoder = AWSConfigINIEncoder()
        encoder.keyEncodingStrategy = .useDefaultKeys
        try encoder.encode(ServicesEntry(entries: [:]), into: &doc, section: "services empty")
        #expect(doc.section("services empty")?.keys.count == 0)
    }
}
