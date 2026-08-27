import AWSConfigINI
import Foundation
import Observation

public struct BookmarkStorage {
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

    public init(
        bookmarkStorage: BookmarkStorage = .default,
        modeStorage: ModePreferenceStorage = .default
    ) {
        self.bookmarkStorage = bookmarkStorage
        self.modeStorage = modeStorage
        phase = .setup
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
        phase = initialPhase
        mode = initialMode ?? modeStorage.load()
    }

    deinit {
        currentAccessURL?.stopAccessingSecurityScopedResource()
    }

    public func resolveStoredBookmark() async {
        guard case .setup = phase else { return }

        guard let data = bookmarkStorage.load() else {
            phase = .setup
            return
        }

        do {
            let (url, isStale) = try bookmarkStorage.resolve(data)

            guard url.startAccessingSecurityScopedResource() else {
                phase = .error(.folderAccessDenied)
                return
            }
            currentAccessURL = url

            if isStale, let refreshed = try? bookmarkStorage.makeBookmark(for: url) {
                bookmarkStorage.save(refreshed)
            }

            phase = .ready(url)
        } catch {
            phase = .error(.bookmarkResolutionFailed(underlying: error))
        }
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
