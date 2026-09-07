import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppPresentationController {
    private(set) var runsInMenuBarOnly: Bool

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        runsInMenuBarOnly = defaults.bool(forKey: AppPresentationPreferences.menuBarOnlyKey)
    }

    func applyCurrentActivationPolicy() {
        NSApplication.shared.setActivationPolicy(runsInMenuBarOnly ? .accessory : .regular)
    }

    func setRunsInMenuBarOnly(_ isEnabled: Bool) {
        guard runsInMenuBarOnly != isEnabled else { return }
        runsInMenuBarOnly = isEnabled
        defaults.set(isEnabled, forKey: AppPresentationPreferences.menuBarOnlyKey)
        applyCurrentActivationPolicy()

        if !isEnabled {
            NSApplication.shared.activate()
        }
    }
}
