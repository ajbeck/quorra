import SwiftUI
import QuorraAppLogic

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .scenePadding()
        .frame(minWidth: 480, idealWidth: 540, minHeight: 320)
    }
}

#if DEBUG

#Preview {
    SettingsView()
        .environment(AppModel(initialPhase: .ready(URL(filePath: "/Users/example/.aws"))))
        .environment(EditorState())
}

#endif
