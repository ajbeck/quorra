import AWSConfigINI
import Foundation
import Observation

@Observable
@MainActor
public final class ProfilesModel {
    public private(set) var configDocument: AWSConfigINIDocument?
    public private(set) var credentialsDocument: AWSConfigINIDocument?
    public private(set) var groups: SidebarGroups = .empty
    public private(set) var loadState: LoadState = .idle

    public enum LoadState {
        case idle
        case loading
        case loaded
        case failed(AWSConfigINIError)
    }

    @ObservationIgnored var currentFolder: URL?
    @ObservationIgnored private var loadGeneration = 0

    private struct LoadedProfiles: Sendable {
        let config: AWSConfigINIDocument
        let credentials: AWSConfigINIDocument
        let groups: SidebarGroups
    }

    public init() {}

    public func load(folder: URL) async {
        let isRefreshingCurrentFolder = currentFolder == folder && loadState == .loaded
        currentFolder = folder
        loadGeneration += 1
        let generation = loadGeneration
        // Keep already-rendered data visible during an in-place reload. Replacing the
        // complete three-column UI with progress views causes unnecessary layout work
        // and can leave navigation looking empty while a profile edit is saved.
        if !isRefreshingCurrentFolder {
            loadState = .loading
        }
        do {
            // File I/O, parsing, decoding, grouping, and sorting can all grow with
            // the user's AWS configuration. None of that work needs the main actor.
            let loaded = try await Task.detached(priority: .userInitiated) {
                try Self.loadProfiles(from: folder)
            }.value
            guard generation == loadGeneration else { return }

            configDocument = loaded.config
            credentialsDocument = loaded.credentials
            groups = loaded.groups
            loadState = .loaded
        } catch let error as AWSConfigINIError {
            guard generation == loadGeneration else { return }
            loadState = .failed(error)
        } catch {
            guard generation == loadGeneration else { return }
            loadState = .failed(.malformedInput(error.localizedDescription))
        }
    }

    public func reload() async {
        guard let folder = currentFolder else { return }
        await load(folder: folder)
    }

    private nonisolated static func loadProfiles(from folder: URL) throws -> LoadedProfiles {
        let configURL = folder.appending(path: "config", directoryHint: .notDirectory)
        let credentialsURL = folder.appending(path: "credentials", directoryHint: .notDirectory)
        let config = try readOrEmpty(configURL, flavor: .config)
        let credentials = try readOrEmpty(credentialsURL, flavor: .credentials)

        return LoadedProfiles(
            config: config,
            credentials: credentials,
            groups: derive(config: config, credentials: credentials)
        )
    }

    private nonisolated static func readOrEmpty(
        _ url: URL,
        flavor: FileFlavor
    ) throws -> AWSConfigINIDocument {
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            return try AWSConfigINIDocument(contentsOf: url, flavor: flavor)
        }
        return AWSConfigINIDocument(empty: flavor)
    }

    /// Derives the sidebar view-model from parsed config and credentials documents.
    /// This is deliberately pure: it has no file I/O and is independently testable.
    public nonisolated static func derive(
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
            let session = try? decoder.decode(SSOSession.self, from: config, section: "sso-session \(sessionName)")
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

    private nonisolated static func profileNames(from document: AWSConfigINIDocument) -> [String] {
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

    private nonisolated static func ssoSessionNames(from config: AWSConfigINIDocument) -> [String] {
        config.sections.compactMap { section in
            guard section.name.hasPrefix("sso-session ") else { return nil }
            let sessionName = String(section.name.dropFirst("sso-session ".count))
            return sessionName.isEmpty ? nil : sessionName
        }
    }

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

    private nonisolated static func isLongTermKey(node: ProfileNode, config: AWSConfigINIDocument) -> Bool {
        if case .credentialsOnly = node.origin { return true }
        let sectionName = config.flavor.profileSectionName(for: node.id)
        return config.section(sectionName)?.key("aws_access_key_id") != nil
    }

    private nonisolated static func profileSortOrder(_ lhs: ProfileNode, _ rhs: ProfileNode) -> Bool {
        if lhs.id == "default" { return true }
        if rhs.id == "default" { return false }
        return lhs.id < rhs.id
    }

    public func findProfile(named name: String) -> ProfileNode? {
        for session in groups.ssoSessions {
            if let match = session.profiles.first(where: { $0.id == name }) { return match }
        }
        return groups.longTermKeys.first(where: { $0.id == name })
            ?? groups.other.first(where: { $0.id == name })
    }

    public func findSession(named name: String) -> SSOSessionNode? {
        groups.ssoSessions.first(where: { $0.id == name })
    }
}

extension ProfilesModel.LoadState: Equatable {
    public static func == (lhs: ProfilesModel.LoadState, rhs: ProfilesModel.LoadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.loaded, .loaded), (.failed, .failed): return true
        default: return false
        }
    }
}

#if DEBUG
extension ProfilesModel {
    @discardableResult
    func seedLoadedForTesting(
        config: AWSConfigINIDocument,
        credentials: AWSConfigINIDocument,
        folder: URL? = nil
    ) -> SidebarGroups {
        let groups = Self.derive(config: config, credentials: credentials)
        currentFolder = folder
        configDocument = config
        credentialsDocument = credentials
        self.groups = groups
        loadState = .loaded
        return groups
    }

    /// Builds a loaded model from sample text without performing file I/O.
    public static func previewLoaded(
        config: String,
        credentials: String = "",
        folder: URL? = nil
    ) -> ProfilesModel {
        do {
            let model = ProfilesModel()
            let configDocument = try AWSConfigINIDocument(config, flavor: .config)
            let credentialsDocument = credentials.isEmpty
                ? AWSConfigINIDocument(empty: .credentials)
                : try AWSConfigINIDocument(credentials, flavor: .credentials)
            model.seedLoadedForTesting(config: configDocument, credentials: credentialsDocument, folder: folder)
            return model
        } catch {
            preconditionFailure("Invalid ProfilesModel preview fixture: \(error)")
        }
    }
}
#endif
