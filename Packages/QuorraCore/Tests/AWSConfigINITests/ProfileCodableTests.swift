import Testing
import Foundation
@testable import AWSConfigINI

@Suite("Profile — ssoAccountId / ssoRoleName")
struct ProfileCodableTests {

    @Test func decodeSSOProfileWithAccountIdAndRoleName() throws {
        let ini = "[profile dev]\nregion = us-east-1\nsso_session = corp-sso\nsso_account_id = 412903117204\nsso_role_name = AdministratorAccess\n"
        let doc = try AWSConfigINIDocument(ini, flavor: .config)
        let profile = try AWSConfigINIDecoder().decodeProfile(Profile.self, named: "dev", from: doc)
        #expect(profile.ssoAccountId == "412903117204")
        #expect(profile.ssoRoleName == "AdministratorAccess")
    }

    @Test func encodeSSOProfileProducesSnakeCaseKeys() throws {
        var doc = AWSConfigINIDocument(empty: .config)
        let profile = Profile(
            region: "us-east-1",
            ssoSession: "corp-sso",
            ssoAccountId: "412903117204",
            ssoRoleName: "AdministratorAccess"
        )
        try AWSConfigINIEncoder().encodeProfile(profile, named: "dev", into: &doc)
        let section = doc.section("profile dev")!
        #expect(section.key("sso_account_id")?.stringValue == "412903117204")
        #expect(section.key("sso_role_name")?.stringValue == "AdministratorAccess")
    }

    @Test func roundTripPreservesNewFields() throws {
        var doc = AWSConfigINIDocument(empty: .config)
        let original = Profile(
            region: "eu-west-1",
            output: "json",
            ssoSession: "corp-sso",
            ssoAccountId: "412903117204",
            ssoRoleName: "AdministratorAccess"
        )
        try AWSConfigINIEncoder().encodeProfile(original, named: "dev", into: &doc)
        let reparsed = try AWSConfigINIDocument(try doc.write(), flavor: .config)
        let decoded = try AWSConfigINIDecoder().decodeProfile(Profile.self, named: "dev", from: reparsed)
        #expect(decoded == original)
    }

    @Test func legacyInlineSSOProfileRoundTripPreservesStartUrlAndRegion() throws {
        let ini = """
        [profile legacy]
        region = us-east-1
        sso_start_url = https://example.awsapps.com/start
        sso_region = us-west-2
        sso_account_id = 412903117204
        sso_role_name = AdministratorAccess
        """
        var doc = try AWSConfigINIDocument(ini, flavor: .config)
        let profile = try AWSConfigINIDecoder().decodeProfile(Profile.self, named: "legacy", from: doc)

        #expect(profile.ssoStartUrl == "https://example.awsapps.com/start")
        #expect(profile.ssoRegion == "us-west-2")

        try AWSConfigINIEncoder().encodeProfile(profile, named: "legacy", into: &doc)
        let section = doc.section("profile legacy")!
        #expect(section.key("sso_start_url")?.stringValue == "https://example.awsapps.com/start")
        #expect(section.key("sso_region")?.stringValue == "us-west-2")
        #expect(section.key("sso_account_id")?.stringValue == "412903117204")
        #expect(section.key("sso_role_name")?.stringValue == "AdministratorAccess")
    }

    @Test func decodeOldStyleProfileYieldsNilNewFields() throws {
        let ini = "[profile legacy]\nregion = us-east-1\ncredential_process = /usr/bin/aws-creds\n"
        let doc = try AWSConfigINIDocument(ini, flavor: .config)
        let profile = try AWSConfigINIDecoder().decodeProfile(Profile.self, named: "legacy", from: doc)
        #expect(profile.ssoStartUrl == nil)
        #expect(profile.ssoRegion == nil)
        #expect(profile.ssoAccountId == nil)
        #expect(profile.ssoRoleName == nil)
    }
}
