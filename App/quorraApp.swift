import SwiftUI

@main
struct quorraApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
        }

        Settings {
            SettingsView()
                .environment(appModel)
        }
    }
}
