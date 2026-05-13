import SwiftUI
import IAMIdentityCenter

@main
struct quorraApp: App {
    @State private var appModel = AppModel()
    @State private var profilesModel = ProfilesModel()
    @State private var editorState = EditorState()
    @State private var credentialsModel = CredentialsModel(
        service: IdentityCenterService(
            keychain: Keychain(accessGroup: KeychainAccessGroup.shared),
            oidcClient: OIDCClient(region: "us-east-1")
        )
    )

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .environment(profilesModel)
                .environment(editorState)
                .environment(credentialsModel)
        }
        .defaultSize(width: 960, height: 640)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(appModel)
                .environment(editorState)
        }
    }
}
