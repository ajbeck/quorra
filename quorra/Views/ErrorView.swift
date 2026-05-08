import SwiftUI

struct ErrorView: View {
    let error: AppError

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Something went wrong")
                .font(.title2)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 320)
    }

    private var message: String {
        switch error {
        case .bookmarkResolutionFailed(let underlying):
            return "Couldn't resolve your saved folder: \(underlying.localizedDescription)"
        case .folderAccessDenied:
            return "macOS refused access to your saved folder. Choose a new one."
        case .folderMissing:
            return "Your saved folder no longer exists. Choose a new one."
        }
    }
}

#Preview("Error – folderMissing") {
    ErrorView(error: .folderMissing)
        .environment(AppModel(initialPhase: .error(.folderMissing)))
}

#Preview("Error – folderAccessDenied") {
    ErrorView(error: .folderAccessDenied)
        .environment(AppModel(initialPhase: .error(.folderAccessDenied)))
}
