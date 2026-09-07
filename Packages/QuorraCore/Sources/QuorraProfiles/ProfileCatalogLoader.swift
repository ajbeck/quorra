import AWSConfigINI
import Foundation

/// Loads and derives AWS profile data without depending on UI or main-actor state.
public enum ProfileCatalogLoader {
    public static func load(folder: URL) throws -> ProfileCatalog {
        try load(
            configURL: folder.appending(path: "config", directoryHint: .notDirectory),
            credentialsURL: folder.appending(path: "credentials", directoryHint: .notDirectory)
        )
    }

    public static func load(configURL: URL, credentialsURL: URL) throws -> ProfileCatalog {
        let config = try readOrEmpty(configURL, flavor: .config)
        let credentials = try readOrEmpty(credentialsURL, flavor: .credentials)

        return ProfileCatalog(
            configDocument: config,
            credentialsDocument: credentials,
            groups: derive(config: config, credentials: credentials)
        )
    }

    public static func derive(
        config: AWSConfigINIDocument,
        credentials: AWSConfigINIDocument
    ) -> SidebarGroups {
        let decoder = AWSConfigINIDecoder()
        var allProfileNames: [String] = []
        var seenNames: Set<String> = []

        for name in profileNames(from: config) + profileNames(from: credentials) {
            if seenNames.insert(name).inserted {
                allProfileNames.append(name)
            }
        }

        var profileNodes: [String: ProfileNode] = [:]
        var profilesBySession: [String: [ProfileNode]] = [:]
        for name in allProfileNames {
            let inConfig = config.profileSection(named: name) != nil
            let inCredentials = credentials.profileSection(named: name) != nil
            let origin: ProfileNode.Origin = if inConfig && inCredentials {
                .both
            } else if inConfig {
                .configOnly
            } else {
                .credentialsOnly
            }

            // Keep malformed sections visible rather than silently dropping a profile.
            let configProfile = inConfig
                ? (try? decoder.decodeProfile(Profile.self, named: name, from: config)) ?? Profile()
                : Profile()
            let credentialsProfile = inCredentials
                ? (try? decoder.decodeProfile(Profile.self, named: name, from: credentials)) ?? Profile()
                : Profile()
            let merged: Profile = if inConfig && inCredentials {
                mergeProfiles(base: configProfile, overlay: credentialsProfile)
            } else if inConfig {
                configProfile
            } else {
                credentialsProfile
            }
            let node = ProfileNode(id: name, profile: merged, origin: origin)
            profileNodes[name] = node
            if let sessionName = merged.ssoSession {
                profilesBySession[sessionName, default: []].append(node)
            }
        }

        var ssoSessionNodes: [SSOSessionNode] = []
        var profilesAlreadyBucketed: Set<String> = []
        for sessionName in ssoSessionNames(from: config) {
            let session = try? decoder.decode(
                SSOSession.self,
                from: config,
                section: "sso-session \(sessionName)"
            )
            let rooted = (profilesBySession[sessionName] ?? []).sorted(by: profileSortOrder)
            profilesAlreadyBucketed.formUnion(rooted.map(\.id))
            ssoSessionNodes.append(SSOSessionNode(id: sessionName, session: session, profiles: rooted))
        }

        var longTermKeys: [ProfileNode] = []
        var other: [ProfileNode] = []
        for name in allProfileNames where !profilesAlreadyBucketed.contains(name) {
            guard let node = profileNodes[name] else { continue }
            if isLongTermKey(node: node, config: config) {
                longTermKeys.append(node)
            } else {
                other.append(node)
            }
        }
        longTermKeys.sort(by: profileSortOrder)
        other.sort(by: profileSortOrder)
        return SidebarGroups(ssoSessions: ssoSessionNodes, longTermKeys: longTermKeys, other: other)
    }

    private static func readOrEmpty(_ url: URL, flavor: FileFlavor) throws -> AWSConfigINIDocument {
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            return try AWSConfigINIDocument(contentsOf: url, flavor: flavor)
        }
        return AWSConfigINIDocument(empty: flavor)
    }

    private static func profileNames(from document: AWSConfigINIDocument) -> [String] {
        document.sections.compactMap { section in
            let name = section.name
            if document.flavor == .config {
                if name == "default" { return "default" }
                guard name.hasPrefix("profile ") else { return nil }
                let profileName = String(name.dropFirst("profile ".count))
                return profileName.isEmpty ? nil : profileName
            }
            return name
        }
    }

    private static func ssoSessionNames(from config: AWSConfigINIDocument) -> [String] {
        config.sections.compactMap { section in
            guard section.name.hasPrefix("sso-session ") else { return nil }
            let sessionName = String(section.name.dropFirst("sso-session ".count))
            return sessionName.isEmpty ? nil : sessionName
        }
    }

    private static func mergeProfiles(base: Profile, overlay: Profile) -> Profile {
        Profile(
            region: overlay.region ?? base.region,
            output: overlay.output ?? base.output,
            ssoSession: overlay.ssoSession ?? base.ssoSession,
            ssoAccountId: overlay.ssoAccountId ?? base.ssoAccountId,
            ssoRoleName: overlay.ssoRoleName ?? base.ssoRoleName,
            credentialProcess: overlay.credentialProcess ?? base.credentialProcess,
            sourceProfile: overlay.sourceProfile ?? base.sourceProfile,
            roleArn: overlay.roleArn ?? base.roleArn,
            roleSessionName: overlay.roleSessionName ?? base.roleSessionName,
            mfaSerial: overlay.mfaSerial ?? base.mfaSerial
        )
    }

    private static func isLongTermKey(node: ProfileNode, config: AWSConfigINIDocument) -> Bool {
        if case .credentialsOnly = node.origin { return true }
        let sectionName = config.flavor.profileSectionName(for: node.id)
        return config.section(sectionName)?.key("aws_access_key_id") != nil
    }

    private static func profileSortOrder(_ lhs: ProfileNode, _ rhs: ProfileNode) -> Bool {
        if lhs.id == "default" { return true }
        if rhs.id == "default" { return false }
        return lhs.id < rhs.id
    }
}
