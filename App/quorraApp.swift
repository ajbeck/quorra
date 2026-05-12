import SwiftUI

@main
struct quorraApp: App {
    @State private var appModel = AppModel()
    @State private var profilesModel = ProfilesModel()
    @State private var editorState = EditorState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .environment(profilesModel)
                .environment(editorState)
        }

        Settings {
            SettingsView()
                .environment(appModel)
                .environment(editorState)
        }
    }
}
