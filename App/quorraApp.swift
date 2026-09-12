import SwiftUI
import SwiftData

@main
struct quorraApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Quorra", id: QuorraSceneID.mainWindow) {
            RootView()
                .environment(appDelegate.appModel)
                .environment(appDelegate.profilesModel)
                .environment(appDelegate.editorState)
                .environment(appDelegate.credentialsModel)
                .environment(appDelegate.imdsModel)
                .environment(appDelegate.imdsHelperController)
                .environment(appDelegate.notificationCoordinator)
                .environment(appDelegate.runtimeCoordinator)
                .environment(\.authBrowserPresenter, appDelegate.authBrowserPresenter)
        }
        .modelContainer(appDelegate.metadataContainer)
        .defaultSize(width: 1280, height: 760)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(appDelegate.presentationController.runsInMenuBarOnly ? .suppressed : .automatic)
        .restorationBehavior(appDelegate.presentationController.runsInMenuBarOnly ? .disabled : .automatic)
        .handlesExternalEvents(matching: [AppNavigationRoute.externalEventMatchPrefix])
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appDelegate.appUpdater.checkForUpdates()
                }
            }
        }

        MenuBarExtra("Quorra", image: "QuorraMenuBarIcon") {
            QuorraMenuBarView(
                appUpdater: appDelegate.appUpdater,
                presentationController: appDelegate.presentationController,
                runtimeCoordinator: appDelegate.runtimeCoordinator,
                imdsModel: appDelegate.imdsModel,
                notificationCoordinator: appDelegate.notificationCoordinator
            )
        }

        Settings {
            SettingsView()
                .environment(appDelegate.appModel)
                .environment(appDelegate.appUpdater)
                .environment(appDelegate.editorState)
                .environment(appDelegate.presentationController)
                .environment(appDelegate.launchAtLoginController)
                .environment(appDelegate.imdsHelperController)
        }
        .modelContainer(appDelegate.metadataContainer)
    }
}
