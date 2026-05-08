import Foundation
import Observation

@Observable
final class AppModel {
    private(set) var phase: AppPhase

    @ObservationIgnored private let storage: BookmarkStorage
    @ObservationIgnored private var currentAccessURL: URL?

    init(storage: BookmarkStorage = .default) {
        self.storage = storage
        self.phase = .setup
    }

    init(storage: BookmarkStorage = .default, initialPhase: AppPhase) {
        self.storage = storage
        self.phase = initialPhase
    }

    deinit {
        currentAccessURL?.stopAccessingSecurityScopedResource()
    }

    func resolveStoredBookmark() async {
        guard case .setup = phase else { return }

        guard let data = storage.load() else {
            phase = .setup
            return
        }

        do {
            let (url, isStale) = try storage.resolve(data)

            guard url.startAccessingSecurityScopedResource() else {
                phase = .error(.folderAccessDenied)
                return
            }
            currentAccessURL = url

            if isStale, let refreshed = try? storage.makeBookmark(for: url) {
                storage.save(refreshed)
            }

            phase = .ready(url)
        } catch {
            phase = .error(.bookmarkResolutionFailed(underlying: error))
        }
    }

    func completeSetup(selectedFolder url: URL) async {
        do {
            let data = try storage.makeBookmark(for: url)
            storage.save(data)
            currentAccessURL = url
            phase = .ready(url)
        } catch {
            phase = .error(.bookmarkResolutionFailed(underlying: error))
        }
    }

    func resetToSetup() async {
        currentAccessURL?.stopAccessingSecurityScopedResource()
        currentAccessURL = nil
        storage.clear()
        phase = .setup
    }
}
