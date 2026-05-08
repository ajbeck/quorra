import SwiftUI

struct SetupView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Setup")
                .font(.largeTitle)
            Text("Placeholder — feature bullets and folder picker land here in a later commit.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 320)
    }
}

#Preview("Setup") {
    SetupView()
        .environment(AppModel(initialPhase: .setup))
}
