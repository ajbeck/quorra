import SwiftUI

/// The menu bar icon: the Quorra glyph, with a badge while something needs the user, such as a
/// sign-in or a failed endpoint. Both images are template images so macOS tints them for the
/// menu bar's appearance; the accessibility label names the reason.
struct QuorraMenuBarLabel: View {
    let runtimeCoordinator: AppRuntimeCoordinator

    var body: some View {
        if let reason = runtimeCoordinator.attentionReason {
            Image("QuorraMenuBarIconAttention")
                .accessibilityLabel("Quorra, \(reason)")
        } else {
            Image("QuorraMenuBarIcon")
                .accessibilityLabel("Quorra")
        }
    }
}
