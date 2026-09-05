import AWSConfigINI
import Foundation
import Observation

public struct BookmarkStorage: @unchecked Sendable {
    public static let key = "dev.ajbeck.quorra.awsFolderBookmark"

    public static var `default`: BookmarkStorage {
        BookmarkStorage(defaults: .standard)
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load() -> Data? {
        defaults.data(forKey: Self.key)
    }

    public func save(_ data: Data) {
        defaults.set(data, forKey: Self.key)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    public func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }
}

public struct ModePreferenceStorage {
    public static let key = "dev.ajbeck.quorra.managedMode"

    public static var `default`: ModePreferenceStorage {
        ModePreferenceStorage(defaults: .standard)
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Returns the persisted mode, or `.managed` when absent or unparseable.
    public func load() -> ManagedMode {
        guard let raw = defaults.string(forKey: Self.key) else { return .managed }
        switch raw {
        case "managed":
            return .managed
        case "readOnly":
            return .readOnly
        default:
            return .managed
        }
    }

    public func save(_ mode: ManagedMode) {
        switch mode {
        case .managed:
            defaults.set("managed", forKey: Self.key)
        case .readOnly:
            defaults.set("readOnly", forKey: Self.key)
        }
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

public enum AppPhase {
    case restoring
    case setup
    case ready(URL)
    case error(AppError)
}

public enum AppError: Error {
    case bookmarkResolutionFailed(underlying: any Error)
    case folderAccessDenied
    case folderMissing
}

@Observable
@MainActor
public final class AppModel {
    public private(set) var phase: AppPhase
    public private(set) var mode: ManagedMode

    @ObservationIgnored private let bookmarkStorage: BookmarkStorage
    @ObservationIgnored private let modeStorage: ModePreferenceStorage
    @ObservationIgnored private var currentAccessURL: URL?
    @ObservationIgnored private var pendingBookmarkData: Data?
    @ObservationIgnored private var resolutionGeneration = 0

    private enum ResolvedBookmark: Sendable {
        case ready(URL)
        case accessDenied
    }

    public init(
        bookmarkStorage: BookmarkStorage = .default,
        modeStorage: ModePreferenceStorage = .default
    ) {
        self.bookmarkStorage = bookmarkStorage
        self.modeStorage = modeStorage
        let bookmarkData = bookmarkStorage.load()
        pendingBookmarkData = bookmarkData
        phase = bookmarkData == nil ? .setup : .restoring
        mode = modeStorage.load()
    }

    public init(
        bookmarkStorage: BookmarkStorage = .default,
        modeStorage: ModePreferenceStorage = .default,
        initialPhase: AppPhase,
        initialMode: ManagedMode? = nil
    ) {
        self.bookmarkStorage = bookmarkStorage
        self.modeStorage = modeStorage
        pendingBookmarkData = nil
        phase = initialPhase
        mode = initialMode ?? modeStorage.load()
    }

    deinit {
        currentAccessURL?.stopAccessingSecurityScopedResource()
    }

    public func resolveStoredBookmark() async {
        switch phase {
        case .setup, .restoring:
            break
        case .ready, .error:
            return
        }

        guard let data = pendingBookmarkData ?? bookmarkStorage.load() else {
            phase = .setup
            return
        }
        pendingBookmarkData = nil
        resolutionGeneration += 1
        let generation = resolutionGeneration
        let storage = bookmarkStorage

        do {
            // Bookmark resolution can synchronously consult the file system and the
            // security-scoped resource service. Keep both off the main actor so the
            // first window remains responsive while access is restored.
            let resolved = try await Task.detached(priority: .userInitiated) {
                try Self.resolveBookmark(data, using: storage)
            }.value
            guard generation == resolutionGeneration else {
                if case .ready(let url) = resolved {
                    url.stopAccessingSecurityScopedResource()
                }
                return
            }

            guard case .ready(let url) = resolved else {
                phase = .error(.folderAccessDenied)
                return
            }
            currentAccessURL = url
            phase = .ready(url)
        } catch {
            guard generation == resolutionGeneration else { return }
            phase = .error(.bookmarkResolutionFailed(underlying: error))
        }
    }

    private nonisolated static func resolveBookmark(
        _ data: Data,
        using storage: BookmarkStorage
    ) throws -> ResolvedBookmark {
        let (url, isStale) = try storage.resolve(data)
        guard url.startAccessingSecurityScopedResource() else {
            return .accessDenied
        }

        if isStale, let refreshed = try? storage.makeBookmark(for: url) {
            storage.save(refreshed)
        }
        return .ready(url)
    }

    public func completeSetup(selectedFolder url: URL, mode newMode: ManagedMode) async {
        modeStorage.save(newMode)
        mode = newMode
        do {
            let data = try bookmarkStorage.makeBookmark(for: url)
            bookmarkStorage.save(data)
            currentAccessURL = url
            phase = .ready(url)
        } catch {
            phase = .error(.bookmarkResolutionFailed(underlying: error))
        }
    }

    /// Persists before publishing so the worst-case inconsistency is
    /// "stale observer / correct disk" rather than "updated observer / lost disk write".
    public func setMode(_ newMode: ManagedMode) async {
        modeStorage.save(newMode)
        mode = newMode
    }

    public func resetToSetup() async {
        resolutionGeneration += 1
        currentAccessURL?.stopAccessingSecurityScopedResource()
        currentAccessURL = nil
        bookmarkStorage.clear()
        phase = .setup
    }

    /// Re-runs bookmark resolution from an error state — used by "Try Again".
    /// Returns the app to `.setup` first so resolveStoredBookmark's guard passes.
    public func retryResolution() async {
        currentAccessURL?.stopAccessingSecurityScopedResource()
        currentAccessURL = nil
        phase = .setup
        await resolveStoredBookmark()
    }
}
