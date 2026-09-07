import AppKit
import QuorraAppLogic
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppRuntimeCoordinator.self) private var runtimeCoordinator
    @Environment(DefaultIMDSNotificationCoordinator.self) private var notificationCoordinator

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
        .alert(
            "Default IMDS Endpoint needs sign-in",
            isPresented: Binding(
                get: { runtimeCoordinator.authenticationNotice != nil },
                set: { if !$0 { runtimeCoordinator.dismissAuthenticationNotice() } }
            ),
            presenting: runtimeCoordinator.authenticationNotice
        ) { notice in
            Button("Sign In") {
                notificationCoordinator.requestEndpointOpen()
                runtimeCoordinator.signIn(to: notice.sessionName)
            }
            Button("Not Now", role: .cancel) {
                runtimeCoordinator.dismissAuthenticationNotice()
            }
        } message: { notice in
            Text("The active profile “\(notice.profileName)” needs you to sign in before the Default IMDS Endpoint can resume on 127.0.0.1:7114.")
        }
        .handlesExternalEvents(
            preferring: [AppNavigationRoute.externalEventMatchPrefix],
            allowing: [AppNavigationRoute.externalEventMatchPrefix]
        )
        .onOpenURL { url in
            guard AppNavigationRoute(url: url) == .defaultIMDSEndpoint else { return }
            notificationCoordinator.requestEndpointOpen()
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
}

#Preview("Root – ready") {
    let url = URL(filePath: "/Users/example/.aws")
    RootView()
        .environment(AppModel(initialPhase: .ready(url)))
        .environment(AppRuntimeCoordinator.preview())
        .environment(DefaultIMDSNotificationCoordinator())
}

#Preview("Root – error") {
    RootView()
        .environment(AppModel(initialPhase: .error(.folderMissing)))
        .environment(AppRuntimeCoordinator.preview())
        .environment(DefaultIMDSNotificationCoordinator())
}

#endif
