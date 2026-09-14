import Foundation
import SwiftData
import Testing
@testable import QuorraAppLogic

@Suite("Identity store lookups")
struct IdentityStoreTests {
    @MainActor
    @Test func eligible_profiles_need_a_session_and_sort_by_name() throws {
        let container = try QuorraMetadataSchema.makeContainer(inMemory: true)
        let context = container.mainContext
        let session = SessionDefinition(name: "acme", startURL: "https://acme.awsapps.com/start", region: "us-east-1")
        context.insert(session)
        context.insert(ProfileDefinition(name: "profile10", session: session, accountID: "111111111111", roleName: "Admin"))
        context.insert(ProfileDefinition(name: "profile2", session: session, accountID: "222222222222", roleName: "Admin"))
        context.insert(ProfileDefinition(name: "orphan", session: nil, accountID: "333333333333", roleName: "Admin"))
        try context.save()

        #expect(try IdentityStore.eligibleProfiles(in: context).map(\.name) == ["profile2", "profile10"])
        #expect(try IdentityStore.profile(named: "orphan", in: context)?.session == nil)
        #expect(try IdentityStore.profile(named: "missing", in: context) == nil)
        #expect(try IdentityStore.session(named: "acme", in: context)?.startURL == "https://acme.awsapps.com/start")
        #expect(try IdentityStore.sessions(in: context).map(\.name) == ["acme"])
    }
}
