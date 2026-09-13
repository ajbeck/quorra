import Foundation

enum AppPresentationPreferences {
    static let appGroupIdentifier = "9GEBAJV9R4.quorra"
    static let menuBarOnlyKey = "dev.ajbeck.quorra.menu-bar-only"

    static func sharedDefaults(
        standardDefaults: UserDefaults = .standard
    ) -> UserDefaults {
        guard let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return standardDefaults
        }

        if sharedDefaults.object(forKey: menuBarOnlyKey) == nil,
           let existingValue = standardDefaults.object(forKey: menuBarOnlyKey) {
            sharedDefaults.set(existingValue, forKey: menuBarOnlyKey)
        }
        return sharedDefaults
    }
}

enum QuorraSceneID {
    static let mainWindow = "main"
}
