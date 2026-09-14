import Foundation
import SwiftData

/// An account and role reachable through a `SessionDefinition`. Mirrors the `profile` section of the
/// AWS shared config file (`sso_session`, `sso_account_id`, `sso_role_name`, `region`).
@Model
public final class ProfileDefinition {
    #Unique<ProfileDefinition>([\.stableIDString], [\.name])

    public var stableIDString: String
    public var name: String
    public var accountID: String
    public var roleName: String
    public var region: String?
    public var createdAt: Date
    public var updatedAt: Date

    public var session: SessionDefinition?

    @Relationship(deleteRule: .nullify, inverse: \IMDSEndpointDefinition.profile)
    public var endpoints: [IMDSEndpointDefinition]

    public init(
        id: UUID = UUID(),
        name: String,
        session: SessionDefinition?,
        accountID: String,
        roleName: String,
        region: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.stableIDString = id.uuidString
        self.name = name
        self.session = session
        self.accountID = accountID
        self.roleName = roleName
        self.region = region
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.endpoints = []
    }

    public var stableID: UUID {
        get { UUID(uuidString: stableIDString) ?? UUID() }
        set {
            stableIDString = newValue.uuidString
            updatedAt = .now
        }
    }
}

public extension ProfileDefinition {
    /// The Identity Center coordinates credentials are keyed by, or `nil` when the profile has no session.
    var credentialCoordinates: (session: String, account: String, role: String, region: String, key: String)? {
        guard let session else { return nil }
        return (session.name, accountID, roleName, region ?? "us-east-1", "\(session.name):\(accountID):\(roleName)")
    }
}
