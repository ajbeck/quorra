import Foundation
import SwiftData
import Testing
@testable import QuorraAppLogic

@Suite("Identity models")
struct IdentityModelTests {
    @MainActor
    @Test func deleting_a_session_deletes_its_profiles() throws {
        let container = try QuorraMetadataSchema.makeContainer(inMemory: true)
        let context = container.mainContext
        let session = SessionDefinition(name: "work", startURL: "https://example.awsapps.com/start", region: "us-east-1")
        context.insert(session)
        context.insert(ProfileDefinition(name: "work:admin", session: session, accountID: "111122223333", roleName: "Admin"))
        context.insert(ProfileDefinition(name: "work:readonly", session: session, accountID: "111122223333", roleName: "ReadOnly"))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<ProfileDefinition>()) == 2)

        context.delete(session)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<SessionDefinition>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ProfileDefinition>()) == 0)
    }

    @MainActor
    @Test func deleting_a_profile_clears_the_endpoint_link() throws {
        let container = try QuorraMetadataSchema.makeContainer(inMemory: true)
        let context = container.mainContext
        let session = SessionDefinition(name: "work", startURL: "https://example.awsapps.com/start", region: "us-east-1")
        let profile = ProfileDefinition(name: "work:admin", session: session, accountID: "111122223333", roleName: "Admin")
        let endpoint = IMDSEndpointDefinition(name: "Terraform", profileName: "work:admin", port: 9678)
        context.insert(session)
        context.insert(profile)
        context.insert(endpoint)
        endpoint.profile = profile
        try context.save()
        #expect(profile.endpoints.count == 1)

        context.delete(profile)
        try context.save()

        #expect(endpoint.profile == nil)
        #expect(try context.fetchCount(FetchDescriptor<IMDSEndpointDefinition>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<SessionDefinition>()) == 1)
    }

    @MainActor
    @Test func session_names_are_unique() throws {
        let container = try QuorraMetadataSchema.makeContainer(inMemory: true)
        let context = container.mainContext
        context.insert(SessionDefinition(name: "work", startURL: "https://one.awsapps.com/start", region: "us-east-1"))
        try context.save()
        context.insert(SessionDefinition(name: "work", startURL: "https://two.awsapps.com/start", region: "eu-west-1"))
        try context.save()

        let sessions = try context.fetch(FetchDescriptor<SessionDefinition>())
        #expect(sessions.count == 1)
        #expect(sessions.first?.startURL == "https://two.awsapps.com/start")
    }

    @MainActor
    @Test func profile_names_are_unique() throws {
        let container = try QuorraMetadataSchema.makeContainer(inMemory: true)
        let context = container.mainContext
        let session = SessionDefinition(name: "work", startURL: "https://example.awsapps.com/start", region: "us-east-1")
        context.insert(session)
        context.insert(ProfileDefinition(name: "work:admin", session: session, accountID: "111122223333", roleName: "Admin"))
        try context.save()
        context.insert(ProfileDefinition(name: "work:admin", session: session, accountID: "444455556666", roleName: "Admin"))
        try context.save()

        let profiles = try context.fetch(FetchDescriptor<ProfileDefinition>())
        #expect(profiles.count == 1)
        #expect(profiles.first?.accountID == "444455556666")
    }
}
