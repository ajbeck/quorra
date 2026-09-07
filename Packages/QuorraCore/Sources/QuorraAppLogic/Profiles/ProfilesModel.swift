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
            let catalog = try await Task.detached(priority: .userInitiated) {
                try ProfileCatalogLoader.load(folder: folder)
            }.value
            guard generation == loadGeneration else { return }

            configDocument = catalog.configDocument
            credentialsDocument = catalog.credentialsDocument
            groups = catalog.groups
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

    /// Derives the sidebar view-model from parsed config and credentials documents.
    /// This is deliberately pure: it has no file I/O and is independently testable.
    public nonisolated static func derive(
        config: AWSConfigINIDocument,
        credentials: AWSConfigINIDocument
    ) -> SidebarGroups {
        ProfileCatalogLoader.derive(config: config, credentials: credentials)
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
