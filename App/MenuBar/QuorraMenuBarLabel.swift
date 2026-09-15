import SwiftUI

/// The menu bar icon. It switches to the sign-in symbol the other calls to action use while the
/// served profile's session needs the user, the way system extras change their symbol with state.
struct QuorraMenuBarLabel: View {
    let runtimeCoordinator: AppRuntimeCoordinator

    var body: some View {
        if runtimeCoordinator.defaultEndpointSignInSessionName != nil {
            Image(systemName: "person.badge.key")
                .accessibilityLabel("Quorra, sign-in needed")
        } else {
            Image("QuorraMenuBarIcon")
                .accessibilityLabel("Quorra")
        }
    }
}
