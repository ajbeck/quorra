import SwiftUI

@main
struct quorraApp: App {
    @State private var appModel = AppModel()
    @State private var profilesModel = ProfilesModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .environment(profilesModel)
        }

        Settings {
            SettingsView()
                .environment(appModel)
        }
    }
}
