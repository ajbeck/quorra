import SwiftUI
import SwiftData

@main
struct quorraApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Quorra", id: QuorraSceneID.mainWindow) {
            RootView()
                .environment(appDelegate.appModel)
                .environment(appDelegate.editorState)
                .environment(appDelegate.credentialsModel)
                .environment(appDelegate.imdsModel)
                .environment(appDelegate.imdsProxyController)
                .environment(appDelegate.notificationCoordinator)
                .environment(appDelegate.runtimeCoordinator)
                .environment(appDelegate.presentationController)
                .environment(\.authenticationBrowser, appDelegate.authenticationBrowser)
                .background(
                    InteractiveWindowRegistration(
                        presentationController: appDelegate.presentationController
                    )
                )
        }
        .modelContainer(appDelegate.metadataContainer)
        .defaultSize(width: 1280, height: 760)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.automatic)
        .restorationBehavior(.automatic)
        .handlesExternalEvents(matching: [AppNavigationRoute.externalEventMatchPrefix])
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appDelegate.appUpdater.checkForUpdates()
                }
            }
        }

        MenuBarExtra {
            QuorraMenuBarView(
                appUpdater: appDelegate.appUpdater,
                presentationController: appDelegate.presentationController,
                runtimeCoordinator: appDelegate.runtimeCoordinator,
                imdsModel: appDelegate.imdsModel,
                notificationCoordinator: appDelegate.notificationCoordinator
            )
        } label: {
            QuorraMenuBarLabel(runtimeCoordinator: appDelegate.runtimeCoordinator)
        }

        Settings {
            SettingsView()
                .environment(appDelegate.appModel)
                .environment(appDelegate.appUpdater)
                .environment(appDelegate.editorState)
                .environment(appDelegate.presentationController)
                .environment(appDelegate.launchAtLoginController)
                .environment(appDelegate.imdsProxyController)
                .environment(appDelegate.runtimeCoordinator)
                .background(
                    InteractiveWindowRegistration(
                        presentationController: appDelegate.presentationController
                    )
                )
        }
        .modelContainer(appDelegate.metadataContainer)
    }
}
