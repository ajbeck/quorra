import SwiftUI

struct MainView: View {
    let folderURL: URL

    var body: some View {
        VStack(spacing: 12) {
            Text("Main")
                .font(.largeTitle)
            Text("Bookmarked folder:")
                .foregroundStyle(.secondary)
            Text(folderURL.path(percentEncoded: false))
                .font(.body.monospaced())
                .textSelection(.enabled)
            Text("Placeholder — folder contents list lands here in a later commit.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 320)
    }
}

#Preview("Main – ready") {
    let url = URL(filePath: "/Users/example/.aws")
    MainView(folderURL: url)
        .environment(AppModel(initialPhase: .ready(url)))
}
