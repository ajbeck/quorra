import AWSConfigINI
import Foundation
import SwiftData

/// A session as the exporter writes it, copied out of the store so the file write can leave the main actor.
public struct ExportedSession: Equatable, Sendable {
    public var name: String
    public var startURL: String
    public var region: String
    public var registrationScopes: [String]

    public init(name: String, startURL: String, region: String, registrationScopes: [String]) {
        self.name = name
        self.startURL = startURL
        self.region = region
        self.registrationScopes = registrationScopes
    }
}

/// A profile as the exporter writes it. Only profiles linked to a session are exported.
public struct ExportedProfile: Equatable, Sendable {
    public var name: String
    public var sessionName: String
    public var accountID: String
    public var roleName: String
    public var region: String?

    public init(name: String, sessionName: String, accountID: String, roleName: String, region: String?) {
        self.name = name
        self.sessionName = sessionName
        self.accountID = accountID
        self.roleName = roleName
        self.region = region
    }
}

/// Everything one export writes.
public struct IdentityExportSnapshot: Equatable, Sendable {
    public var sessions: [ExportedSession]
    public var profiles: [ExportedProfile]

    public init(sessions: [ExportedSession], profiles: [ExportedProfile]) {
        self.sessions = sessions
        self.profiles = profiles
    }

    /// Copies every session, and every profile linked to a session, out of the store.
    @MainActor
    public static func capture(in context: ModelContext) throws -> IdentityExportSnapshot {
        let sessions = try IdentityStore.sessions(in: context).map {
            ExportedSession(name: $0.name, startURL: $0.startURL, region: $0.region, registrationScopes: $0.registrationScopes)
        }
        let profiles = try IdentityStore.eligibleProfiles(in: context).compactMap { profile -> ExportedProfile? in
            guard let session = profile.session else { return nil }
            return ExportedProfile(
                name: profile.name,
                sessionName: session.name,
                accountID: profile.accountID,
                roleName: profile.roleName,
                region: profile.region
            )
        }
        return IdentityExportSnapshot(sessions: sessions, profiles: profiles)
    }
}

/// The names the last export wrote, so the next export can tell which objects were deleted in Quorra since.
public struct IdentityExportRecord: Codable, Equatable, Sendable {
    public var sessionNames: Set<String>
    public var profileNames: Set<String>

    public static let empty = IdentityExportRecord(sessionNames: [], profileNames: [])

    public init(sessionNames: Set<String>, profileNames: Set<String>) {
        self.sessionNames = sessionNames
        self.profileNames = profileNames
    }
}

public struct IdentityExportSummary: Equatable, Sendable {
    public var sessions = 0
    public var profiles = 0
    public var removedSessions = 0
    public var removedProfiles = 0

    public init() {}
}

/// Writes the store's sessions and profiles into the AWS config file (decision D13).
///
/// The exporter owns keys, not sections. It sets the SSO keys of the same-named `sso-session` and
/// `profile` sections and leaves every other key and section alone. When an object was deleted in
/// Quorra since the last export, it removes only those keys and drops the section if nothing is left.
public enum IdentityStoreExporter {
    public static let sessionKeys = ["sso_start_url", "sso_region", "sso_registration_scopes"]
    public static let profileKeys = ["sso_session", "sso_account_id", "sso_role_name", "region"]

    public static func apply(
        _ snapshot: IdentityExportSnapshot,
        previous: IdentityExportRecord,
        to document: inout AWSConfigINIDocument
    ) -> IdentityExportSummary {
        var summary = IdentityExportSummary()

        for name in previous.sessionNames.subtracting(snapshot.sessions.map(\.name)).sorted() {
            removeKeys(sessionKeys, fromSection: sessionSectionName(name), in: &document)
            summary.removedSessions += 1
        }
        for name in previous.profileNames.subtracting(snapshot.profiles.map(\.name)).sorted() {
            removeKeys(profileKeys, fromSection: document.flavor.profileSectionName(for: name), in: &document)
            summary.removedProfiles += 1
        }

        for session in snapshot.sessions {
            let sectionName = sessionSectionName(session.name)
            document.ensureSection(sectionName)
            document.update(sectionName) { section in
                section.setKey("sso_start_url", value: session.startURL)
                section.setKey("sso_region", value: session.region)
                setOrDelete(
                    "sso_registration_scopes",
                    value: session.registrationScopes.isEmpty ? nil : session.registrationScopes.joined(separator: ", "),
                    in: &section
                )
            }
            summary.sessions += 1
        }
        for profile in snapshot.profiles {
            let sectionName = document.flavor.profileSectionName(for: profile.name)
            document.ensureSection(sectionName)
            document.update(sectionName) { section in
                section.setKey("sso_session", value: profile.sessionName)
                section.setKey("sso_account_id", value: profile.accountID)
                section.setKey("sso_role_name", value: profile.roleName)
                setOrDelete("region", value: profile.region, in: &section)
            }
            summary.profiles += 1
        }
        return summary
    }

    /// Writes `snapshot` into the config file at `url` under the shared file lock, creating the file
    /// if it is missing, and returns what it did with the record to remember for the next export.
    public static func export(
        _ snapshot: IdentityExportSnapshot,
        previous: IdentityExportRecord,
        toConfigAt url: URL
    ) throws -> (summary: IdentityExportSummary, record: IdentityExportRecord) {
        var summary = IdentityExportSummary()
        try AWSConfigINIDocument.update(at: url, flavor: .config, mode: .managed) { document in
            summary = apply(snapshot, previous: previous, to: &document)
        }
        let record = IdentityExportRecord(
            sessionNames: Set(snapshot.sessions.map(\.name)),
            profileNames: Set(snapshot.profiles.map(\.name))
        )
        return (summary, record)
    }

    static func sessionSectionName(_ name: String) -> String {
        "sso-session \(name)"
    }

    private static func setOrDelete(_ key: String, value: String?, in section: inout AWSConfigINI.Section) {
        if let value, !value.isEmpty {
            section.setKey(key, value: value)
        } else {
            section.deleteKey(key)
        }
    }

    private static func removeKeys(_ keys: [String], fromSection name: String, in document: inout AWSConfigINIDocument) {
        guard document.section(name) != nil else { return }
        document.update(name) { section in
            for key in keys {
                section.deleteKey(key)
            }
        }
        if document.section(name)?.keys.isEmpty == true {
            document.deleteSection(name)
        }
    }
}
