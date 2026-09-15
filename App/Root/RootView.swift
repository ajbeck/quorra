import AppKit
import QuorraAppLogic
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(DefaultIMDSNotificationCoordinator.self) private var notificationCoordinator
    @Environment(AppPresentationController.self) private var presentationController

    var body: some View {
        Group {
            switch appModel.phase {
            case .restoring:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .setup:
                SetupView()
            case .ready(let url):
                MainView(folderURL: url)
            case .error(let err):
                ErrorView(error: err)
            }
        }
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

#Preview("Root – setup") {
    RootView()
        .environment(AppModel(initialPhase: .setup))
        .environment(AppRuntimeCoordinator.preview())
        .environment(DefaultIMDSNotificationCoordinator())
        .environment(AppPresentationController())
}

#Preview("Root – ready") {
    let url = URL(filePath: "/Users/example/.aws")
    RootView()
        .environment(AppModel(initialPhase: .ready(url)))
        .environment(AppRuntimeCoordinator.preview())
        .environment(DefaultIMDSNotificationCoordinator())
        .environment(AppPresentationController())
}

#Preview("Root – error") {
    RootView()
        .environment(AppModel(initialPhase: .error(.folderMissing)))
        .environment(AppRuntimeCoordinator.preview())
        .environment(DefaultIMDSNotificationCoordinator())
        .environment(AppPresentationController())
}

#endif
