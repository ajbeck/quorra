import SwiftUI

/// The menu bar icon. It stays the Quorra glyph in every state; the menu's header line and its
/// Sign In item carry the sign-in state, and the accessibility label reports it.
struct QuorraMenuBarLabel: View {
    let runtimeCoordinator: AppRuntimeCoordinator

    var body: some View {
        Image("QuorraMenuBarIcon")
            .accessibilityLabel(runtimeCoordinator.defaultEndpointSignInSessionName != nil ? "Quorra, sign-in needed" : "Quorra")
    }
}
