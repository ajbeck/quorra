import Observation
import Sparkle

@Observable
@MainActor
final class AppUpdater {
    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    init(startingUpdater: Bool = false) {
        if startingUpdater {
            start()
        }
    }

    /// Starts Sparkle after the first window has had an opportunity to render.
    /// Constructing the controller lazily keeps updater setup off the critical
    /// path while preserving automatic checks for every normal app launch.
    func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        start()
        controller?.checkForUpdates(nil)
    }
}
