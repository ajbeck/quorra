import AppKit
import IAMIdentityCenter
import QuorraAppLogic
import SwiftData

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    let presentationController: AppPresentationController
    let launchAtLoginController: LaunchAtLoginController
    let imdsProxyController: IMDSProxyController
    let metadataContainer: ModelContainer
    let appModel: AppModel
    let appUpdater: AppUpdater
    let profilesModel: ProfilesModel
    let editorState: EditorState
    let imdsModel: IMDSModel
    let notificationCoordinator: DefaultIMDSNotificationCoordinator
    let authenticationBrowser: AuthenticationBrowser
    let credentialsModel: CredentialsModel
    let runtimeCoordinator: AppRuntimeCoordinator
    let ipcController: AppIPCController

    override init() {
        presentationController = AppPresentationController()
        launchAtLoginController = LaunchAtLoginController()
        imdsProxyController = IMDSProxyController()
        let metadataContainer = try! QuorraMetadataSchema.makeContainer()
        let appModel = AppModel()
        let appUpdater = AppUpdater()
        let profilesModel = ProfilesModel()
        let editorState = EditorState()
        let imdsModel = IMDSModel()
        let notificationCoordinator = DefaultIMDSNotificationCoordinator()
        let authenticationBrowser = AuthenticationBrowser()
        let credentialsModel = CredentialsModel(
            service: IdentityCenterService(
                keychain: Keychain(accessGroup: KeychainAccessGroup.shared),
                oidcClientProvider: SDKOIDCClientProvider()
            )
        )

        self.metadataContainer = metadataContainer
        self.appModel = appModel
        self.appUpdater = appUpdater
        self.profilesModel = profilesModel
        self.editorState = editorState
        self.imdsModel = imdsModel
        self.notificationCoordinator = notificationCoordinator
        self.authenticationBrowser = authenticationBrowser
        self.credentialsModel = credentialsModel
        let runtimeCoordinator = AppRuntimeCoordinator(
            appModel: appModel,
            profilesModel: profilesModel,
            credentialsModel: credentialsModel,
            imdsModel: imdsModel,
            imdsProxyController: imdsProxyController,
            notificationCoordinator: notificationCoordinator,
            authenticationBrowser: authenticationBrowser,
            modelContext: metadataContainer.mainContext
        )
        self.runtimeCoordinator = runtimeCoordinator
        self.ipcController = AppIPCController(
            runtimeCoordinator: runtimeCoordinator,
            profilesModel: profilesModel,
            credentialsModel: credentialsModel,
            imdsModel: imdsModel,
            modelContext: metadataContainer.mainContext
        )
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        presentationController.applyCurrentActivationPolicy()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ipcController.start()

        Task { [weak self] in
            await self?.runtimeCoordinator.start()
        }

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.appUpdater.start()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        launchAtLoginController.refresh()
        Task { [weak self] in
            await self?.imdsProxyController.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        imdsProxyController.stop()
        ipcController.stop()
    }
}
