import Foundation
import Observation
import AWSConfigINI

@Observable
@MainActor
final class ProfilesModel {
    private(set) var configDocument: AWSConfigINIDocument?
    private(set) var credentialsDocument: AWSConfigINIDocument?
    private(set) var groups: SidebarGroups = .empty
    private(set) var loadState: LoadState = .idle

    enum LoadState {
        case idle
        case loading
        case loaded
        case failed(AWSConfigINIError)
    }


    @ObservationIgnored private var currentFolder: URL?

    func load(folder: URL) async {
        currentFolder = folder
        loadState = .loading
        do {
            let configURL = folder.appending(path: "config", directoryHint: .notDirectory)
            let credentialsURL = folder.appending(path: "credentials", directoryHint: .notDirectory)

            let config = try readOrEmpty(configURL, flavor: .config)
            let credentials = try readOrEmpty(credentialsURL, flavor: .credentials)

            configDocument = config
            credentialsDocument = credentials
            groups = ProfilesModel.derive(config: config, credentials: credentials)
            loadState = .loaded
        } catch let error as AWSConfigINIError {
            loadState = .failed(error)
        } catch {
            loadState = .failed(.malformedInput(error.localizedDescription))
        }
    }

    func reload() async {
        guard let folder = currentFolder else { return }
        await load(folder: folder)
    }

    private func readOrEmpty(_ url: URL, flavor: FileFlavor) throws -> AWSConfigINIDocument {
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            return try AWSConfigINIDocument(contentsOf: url, flavor: flavor)
        } else {
            return AWSConfigINIDocument(empty: flavor)
        }
    }

    /// Derives the sidebar view-model from parsed config and credentials documents.
    ///
    /// Pure function — testable independently of ProfilesModel. No file I/O.
    nonisolated static func derive(
        config: AWSConfigINIDocument,
        credentials: AWSConfigINIDocument
    ) -> SidebarGroups {
        let decoder = AWSConfigINIDecoder()

        // Collect all profile names seen across both files, preserving config-file order first.
        var allProfileNames: [String] = []
        var seenNames: Set<String> = []

        let configProfileNames = profileNames(from: config)
        let credentialsProfileNames = profileNames(from: credentials)

        for name in configProfileNames {
            if seenNames.insert(name).inserted {
                allProfileNames.append(name)
            }
        }
        for name in credentialsProfileNames {
            if seenNames.insert(name).inserted {
                allProfileNames.append(name)
            }
        }

        // Build merged ProfileNode for each name.
        var profileNodes: [String: ProfileNode] = [:]
        for name in allProfileNames {
            let inConfig = config.profileSection(named: name) != nil
            let inCredentials = credentials.profileSection(named: name) != nil

            let origin: ProfileNode.Origin
            if inConfig && inCredentials {
                origin = .both
            } else if inConfig {
                origin = .configOnly
            } else {
                origin = .credentialsOnly
            }

            // A decode failure here means the section exists but a typed field couldn't
            // be parsed. We fall back to an empty Profile so the row still surfaces in
            // the sidebar — better than dropping the user's profile silently. Per-node
            // decode warnings will land in Phase 8 when the detail pane can render them.
            let configProfile = (try? decoder.decodeProfile(Profile.self, named: name, from: config)) ?? Profile()
            let credentialsProfile = (try? decoder.decodeProfile(Profile.self, named: name, from: credentials)) ?? Profile()

            let merged: Profile
            if inConfig && inCredentials {
                merged = mergeProfiles(base: configProfile, overlay: credentialsProfile)
            } else if inConfig {
                merged = configProfile
            } else {
                merged = credentialsProfile
            }

            profileNodes[name] = ProfileNode(id: name, profile: merged, origin: origin)
        }

        // Build SSO session nodes in config-file source order.
        var ssoSessionNodes: [SSOSessionNode] = []
        var profilesAlreadyBucketed: Set<String> = []

        let ssoSessionNames = ssoSessionNames(from: config)
        for sessionName in ssoSessionNames {
            let sectionName = "sso-session \(sessionName)"
            let session = try? decoder.decode(SSOSession.self, from: config, section: sectionName)

            let rooted = allProfileNames
                .compactMap { profileNodes[$0] }
                .filter { $0.profile.ssoSession == sessionName }
                .sorted(by: profileSortOrder)

            for node in rooted {
                profilesAlreadyBucketed.insert(node.id)
            }

            ssoSessionNodes.append(SSOSessionNode(id: sessionName, session: session, profiles: rooted))
        }

        // Walk remaining profiles through the long-term-keys / other ladder.
        var longTermKeys: [ProfileNode] = []
        var other: [ProfileNode] = []

        for name in allProfileNames {
            guard !profilesAlreadyBucketed.contains(name), let node = profileNodes[name] else { continue }

            if isLongTermKey(node: node, config: config, credentials: credentials) {
                longTermKeys.append(node)
            } else {
                other.append(node)
            }
        }

        longTermKeys.sort(by: profileSortOrder)
        other.sort(by: profileSortOrder)

        return SidebarGroups(ssoSessions: ssoSessionNodes, longTermKeys: longTermKeys, other: other)
    }

    /// Returns profile names from a document in section-appearance order.
    private nonisolated static func profileNames(from doc: AWSConfigINIDocument) -> [String] {
        doc.sections.compactMap { section in
            let name = section.name
            if doc.flavor == .config {
                if name == "default" { return "default" }
                if name.hasPrefix("profile ") {
                    let stripped = String(name.dropFirst("profile ".count))
                    return stripped.isEmpty ? nil : stripped
                }
                return nil
            } else {
                // credentials: bare section names are profile names (including "default")
                return name
            }
        }
    }

    /// Returns SSO session names from the config document in source order.
    private nonisolated static func ssoSessionNames(from config: AWSConfigINIDocument) -> [String] {
        config.sections.compactMap { section in
            let name = section.name
            guard name.hasPrefix("sso-session ") else { return nil }
            let stripped = String(name.dropFirst("sso-session ".count))
            return stripped.isEmpty ? nil : stripped
        }
    }

    /// Merges two profiles, with `overlay` values winning for any non-nil key.
    private nonisolated static func mergeProfiles(base: Profile, overlay: Profile) -> Profile {
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

    /// Returns true when the profile belongs in the "Long-term keys" group.
    ///
    /// A profile is considered to have long-term keys when:
    /// - It came from credentials only, OR
    /// - The config section explicitly carries `aws_access_key_id` (rare but legal)
    private nonisolated static func isLongTermKey(
        node: ProfileNode,
        config: AWSConfigINIDocument,
        credentials: AWSConfigINIDocument
    ) -> Bool {
        if node.origin == .credentialsOnly { return true }
        // Check config section for aws_access_key_id (unusual but permitted by AWS docs)
        let sectionName = config.flavor.profileSectionName(for: node.id)
        if let section = config.section(sectionName), section.key("aws_access_key_id") != nil {
            return true
        }
        return false
    }

    /// Sort order: "default" always first, then alphabetical by name.
    private nonisolated static func profileSortOrder(_ a: ProfileNode, _ b: ProfileNode) -> Bool {
        if a.id == "default" { return true }
        if b.id == "default" { return false }
        return a.id < b.id
    }
}

extension ProfilesModel.LoadState: Equatable {
    static func == (lhs: ProfilesModel.LoadState, rhs: ProfilesModel.LoadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.loading, .loading): return true
        case (.loaded, .loaded): return true
        case (.failed, .failed): return true
        default: return false
        }
    }
}
