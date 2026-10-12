import AppKit
import QuorraAppLogic
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(DefaultIMDSNotificationCoordinator.self) private var notificationCoordinator
    @Environment(AppPresentationController.self) private var presentationController

    var body: some View {
        MainView(folderURL: appModel.folderURL)
        .handlesExternalEvents(
            preferring: [AppNavigationRoute.externalEventMatchPrefix],
            allowing: [AppNavigationRoute.externalEventMatchPrefix]
        )
        .onOpenURL { url in
            guard let route = AppNavigationRoute(url: url) else { return }
            presentationController.prepareForInteractivePresentation()
            if route == .defaultIMDSEndpoint {
                notificationCoordinator.requestEndpointOpen()
            }
            NSApplication.shared.activate()
        }
    }
}

#if DEBUG
extension ProcessInfo {
    var isRunningForPreviews: Bool {
        environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}
#endif

#if DEBUG

#Preview("Root") {
    RootView()
        .environment(AppModel(folderURL: URL(filePath: "/Users/example/.aws")))
        .environment(AppRuntimeCoordinator.preview())
        .environment(DefaultIMDSNotificationCoordinator())
        .environment(AppPresentationController())
}

#endif
