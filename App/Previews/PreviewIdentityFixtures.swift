#if DEBUG
import Foundation
import QuorraAppLogic
import SwiftData

/// Seeds an in-memory identity store with the sample sessions, profiles, and endpoint the previews share.
@MainActor
enum PreviewIdentityFixtures {
    static let endpointID = UUID(uuidString: "00000000-0000-0000-0000-000000009678")!

    static func makeContainer(seedsEndpoint: Bool = false) -> ModelContainer {
        let container = try! QuorraMetadataSchema.makeContainer(inMemory: true)
        seed(into: container.mainContext, endpoint: seedsEndpoint)
        return container
    }

    static func seed(into context: ModelContext, endpoint: Bool = false) {
        let astrocompute = SessionDefinition(name: "astrocompute", startURL: "https://astrocompute.awsapps.com/start", region: "us-east-2")
        let orionLabs = SessionDefinition(name: "orion-labs", startURL: "https://orion-labs.awsapps.com/start", region: "us-west-2")
        context.insert(astrocompute)
        context.insert(orionLabs)

        let profiles = [
            ProfileDefinition(name: "ac:cp:org_admin", session: astrocompute, accountID: "699475923216", roleName: "OrganizationAdmin", region: "us-east-2"),
            ProfileDefinition(name: "ac:mgmt:admin", session: astrocompute, accountID: "699475923216", roleName: "ManagementAdmin", region: "us-east-2"),
            ProfileDefinition(name: "ac:mgmt:org_admin", session: astrocompute, accountID: "699475923216", roleName: "ManagementOrganizationAdmin", region: "us-east-2"),
            ProfileDefinition(name: "ac:personal:org_admin", session: astrocompute, accountID: "699475923216", roleName: "PersonalOrganizationAdmin", region: "us-east-2"),
            ProfileDefinition(name: "ac:spaceport:org_admin", session: astrocompute, accountID: "699475923216", roleName: "SpaceportOrganizationAdmin", region: "us-east-2"),
            ProfileDefinition(name: "orion:dev:read", session: orionLabs, accountID: "824177590102", roleName: "ReadOnlyAccess", region: "us-west-2"),
            ProfileDefinition(name: "orion:prod:read", session: orionLabs, accountID: "824177590102", roleName: "ReadOnlyAccess", region: "us-west-2"),
        ]
        for profile in profiles {
            context.insert(profile)
        }

        if endpoint {
            let definition = IMDSEndpointDefinition(
                id: endpointID,
                name: "localhost:9678",
                profileName: "ac:cp:org_admin",
                port: 9678
            )
            definition.profile = profiles[0]
            context.insert(definition)
        }
        try! context.save()
    }
}
#endif
