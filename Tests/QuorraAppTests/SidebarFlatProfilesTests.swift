import Testing
import Foundation
import AWSConfigINI
@testable import quorra

@Suite("ProfileVia")
struct ProfileViaTests {

    @Test func session_label_is_the_session_name() {
        #expect(ProfileVia.session("acme").label == "acme")
        #expect(ProfileVia.session("acme").isSSO)
    }

    @Test func neutral_kinds_have_fixed_labels_and_are_not_sso() {
        #expect(ProfileVia.longTerm.label == "long-term")
        #expect(ProfileVia.other.label == "other")
        #expect(!ProfileVia.longTerm.isSSO)
        #expect(!ProfileVia.other.isSSO)
    }
}

@Suite("SidebarGroups.flatProfiles")
struct SidebarFlatProfilesTests {

    /// SSO profiles (`default`, `mango`), one long-term key (`alpha-keys`),
    /// one role-assumption "other" (`beta-role`).
    private func mixedGroups() throws -> SidebarGroups {
        let cfg = try AWSConfigINIDocument("""
[sso-session corp]
sso_region = us-east-1

[default]
sso_session = corp
sso_account_id = 111

[profile mango]
sso_session = corp
sso_account_id = 222

[profile beta-role]
role_arn = arn:aws:iam::123456789012:role/R
source_profile = default
""", flavor: .config)
        let creds = try AWSConfigINIDocument("""
[alpha-keys]
aws_access_key_id = AKID
aws_secret_access_key = SECRET
""", flavor: .credentials)
        return ProfilesModel.derive(config: cfg, credentials: creds)
    }

    @Test func orders_default_first_then_alphabetical_across_buckets() throws {
        let items = try mixedGroups().flatProfiles
        #expect(items.map(\.id) == ["default", "alpha-keys", "beta-role", "mango"])
    }

    @Test func tags_each_profile_with_its_bucket_via() throws {
        let byID = Dictionary(uniqueKeysWithValues: try mixedGroups().flatProfiles.map { ($0.id, $0.via) })
        #expect(byID["default"] == .session("corp"))
        #expect(byID["mango"] == .session("corp"))
        #expect(byID["alpha-keys"] == .longTerm)
        #expect(byID["beta-role"] == .other)
    }

    @Test func empty_groups_produce_no_items() {
        #expect(SidebarGroups.empty.flatProfiles.isEmpty)
    }
}
