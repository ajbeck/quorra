import Foundation
import SwiftData

/// What an import did, for logging and for the settings summary.
public struct IdentityImportSummary: Equatable, Sendable {
    public var sessions = 0
    public var profiles = 0
    /// Profiles under an SSO session that lack an account id or role name and were left in the file.
    public var skippedProfiles: [String] = []
    public var linkedEndpoints = 0

    public init() {}
}

/// Copies the SSO sessions and profiles of an AWS folder into the identity store.
///
/// Records are matched by name, so running the import again updates what is there instead of
/// duplicating it. Sessions without a start URL or region, profiles without an account id or role
/// name, and profiles that do not use IAM Identity Center are left in the file untouched.
@MainActor
public enum IdentityStoreImporter {
    public static func importSSOProfiles(from groups: SidebarGroups, into context: ModelContext) throws -> IdentityImportSummary {
        var summary = IdentityImportSummary()
        var sessionsByName = Dictionary(
            try context.fetch(FetchDescriptor<SessionDefinition>()).map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var profilesByName = Dictionary(
            try context.fetch(FetchDescriptor<ProfileDefinition>()).map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for node in groups.ssoSessions {
            guard let session = node.session,
                  let startURL = session.ssoStartUrl, !startURL.isEmpty,
                  let region = session.ssoRegion, !region.isEmpty else {
                summary.skippedProfiles.append(contentsOf: node.profiles.map(\.id))
                continue
            }
            let scopes = session.ssoRegistrationScopes ?? ["sso:account:access"]
            let definition: SessionDefinition
            if let existing = sessionsByName[node.id] {
                existing.startURL = startURL
                existing.region = region
                existing.registrationScopes = scopes
                existing.updatedAt = .now
                definition = existing
            } else {
                definition = SessionDefinition(name: node.id, startURL: startURL, region: region, registrationScopes: scopes)
                context.insert(definition)
                sessionsByName[node.id] = definition
            }
            summary.sessions += 1

            for profileNode in node.profiles {
                guard let accountID = profileNode.profile.ssoAccountId, !accountID.isEmpty,
                      let roleName = profileNode.profile.ssoRoleName, !roleName.isEmpty else {
                    summary.skippedProfiles.append(profileNode.id)
                    continue
                }
                if let existing = profilesByName[profileNode.id] {
                    existing.session = definition
                    existing.accountID = accountID
                    existing.roleName = roleName
                    existing.region = profileNode.profile.region
                    existing.updatedAt = .now
                } else {
                    let profile = ProfileDefinition(
                        name: profileNode.id,
                        session: definition,
                        accountID: accountID,
                        roleName: roleName,
                        region: profileNode.profile.region
                    )
                    context.insert(profile)
                    profilesByName[profileNode.id] = profile
                }
                summary.profiles += 1
            }
        }

        for endpoint in try context.fetch(FetchDescriptor<IMDSEndpointDefinition>())
        where endpoint.profile == nil && !endpoint.profileName.isEmpty {
            guard let profile = profilesByName[endpoint.profileName] else { continue }
            endpoint.profile = profile
            summary.linkedEndpoints += 1
        }

        try context.save()
        return summary
    }
}
