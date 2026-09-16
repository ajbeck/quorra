import Foundation
import SwiftData

/// An IAM Identity Center session that Quorra owns: the access portal to sign in to and the scopes to
/// request. Mirrors the `sso-session` section of the AWS shared config file so export is one-to-one.
@Model
public final class SessionDefinition {
    #Unique<SessionDefinition>([\.stableIDString], [\.name])

    public var stableIDString: String
    public var name: String
    public var startURL: String
    public var region: String
    public var registrationScopes: [String]
    public var createdAt: Date
    public var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ProfileDefinition.session)
    public var profiles: [ProfileDefinition]

    public init(
        id: UUID = UUID(),
        name: String,
        startURL: String,
        region: String,
        registrationScopes: [String] = ["sso:account:access"],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.stableIDString = id.uuidString
        self.name = name
        self.startURL = startURL
        self.region = region
        self.registrationScopes = registrationScopes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.profiles = []
    }

    public var stableID: UUID {
        get { UUID(uuidString: stableIDString) ?? UUID() }
        set {
            stableIDString = newValue.uuidString
            updatedAt = .now
        }
    }
}
