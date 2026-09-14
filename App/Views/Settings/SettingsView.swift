import SwiftUI
import QuorraAppLogic

struct SettingsView: View {
    @AppStorage("dev.ajbeck.quorra.selected-settings-pane")
    private var selectedPane = SettingsPane.general

    var body: some View {
        TabView(selection: $selectedPane) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }
                .tag(SettingsPane.general)
            BackgroundSettingsTab()
                .tabItem { Label("Background", systemImage: "menubar.rectangle") }
                .tag(SettingsPane.background)
            IMDSSettingsTab()
                .tabItem { Label("IMDS", systemImage: "network") }
                .tag(SettingsPane.imds)
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsPane.about)
        }
        .scenePadding()
        .frame(minWidth: 520, idealWidth: 560, minHeight: 380, idealHeight: 460)
    }
}

private enum SettingsPane: String {
    case general
    case background
    case imds
    case about
}

#if DEBUG

#Preview {
    SettingsView()
        .environment(AppModel(initialPhase: .ready(URL(filePath: "/Users/example/.aws"))))
        .environment(AppUpdater(startingUpdater: false))
        .environment(EditorState())
        .environment(AppPresentationController())
        .environment(LaunchAtLoginController())
        .environment(IMDSProxyController())
        .environment(AppRuntimeCoordinator.preview())
}

#endif
