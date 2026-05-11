import Foundation
import Observation
import AWSConfigINI

@Observable
final class AppModel {
    private(set) var phase: AppPhase
    private(set) var mode: ManagedMode

    @ObservationIgnored private let bookmarkStorage: BookmarkStorage
    @ObservationIgnored private let modeStorage: ModePreferenceStorage
    @ObservationIgnored private var currentAccessURL: URL?

    init(
        bookmarkStorage: BookmarkStorage = .default,
        modeStorage: ModePreferenceStorage = .default
    ) {
        self.bookmarkStorage = bookmarkStorage
        self.modeStorage = modeStorage
        self.phase = .setup
        self.mode = modeStorage.load()
    }

    init(
        bookmarkStorage: BookmarkStorage = .default,
        modeStorage: ModePreferenceStorage = .default,
        initialPhase: AppPhase,
        initialMode: ManagedMode? = nil
    ) {
        self.bookmarkStorage = bookmarkStorage
        self.modeStorage = modeStorage
        self.phase = initialPhase
        self.mode = initialMode ?? modeStorage.load()
    }

    deinit {
        currentAccessURL?.stopAccessingSecurityScopedResource()
    }

    func resolveStoredBookmark() async {
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

    func completeSetup(selectedFolder url: URL, mode newMode: ManagedMode) async {
        modeStorage.save(newMode)
        self.mode = newMode
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
    func setMode(_ newMode: ManagedMode) async {
        modeStorage.save(newMode)
        self.mode = newMode
    }

    func resetToSetup() async {
        currentAccessURL?.stopAccessingSecurityScopedResource()
        currentAccessURL = nil
        bookmarkStorage.clear()
        phase = .setup
    }

    /// Re-runs bookmark resolution from an error state — used by "Try Again".
    /// Returns the app to `.setup` first so resolveStoredBookmark's guard passes.
    func retryResolution() async {
        currentAccessURL?.stopAccessingSecurityScopedResource()
        currentAccessURL = nil
        phase = .setup
        await resolveStoredBookmark()
    }
}
