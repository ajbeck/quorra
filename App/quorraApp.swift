import SwiftUI
import IAMIdentityCenter

@main
struct quorraApp: App {
    @State private var appModel = AppModel()
    @State private var profilesModel = ProfilesModel()
    @State private var editorState = EditorState()
    @State private var imdsModel = IMDSModel()
    @State private var authBrowserPresenter = AuthBrowserPresenter()
    @State private var credentialsModel = CredentialsModel(
        service: IdentityCenterService(
            keychain: Keychain(accessGroup: KeychainAccessGroup.shared),
            oidcClientProvider: SDKOIDCClientProvider()
        )
    )

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .environment(profilesModel)
                .environment(editorState)
                .environment(credentialsModel)
                .environment(imdsModel)
                .environment(\.authBrowserPresenter, authBrowserPresenter)
        }
        .defaultSize(width: 1280, height: 760)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(appModel)
                .environment(editorState)
        }
    }
}
