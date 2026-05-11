import SwiftUI
import AWSConfigINI

struct DetailView: View {
    @Binding var selection: SidebarSelection?
    @Environment(AppModel.self) private var appModel
    @Environment(ProfilesModel.self) private var profilesModel

    var body: some View {
        switch (profilesModel.loadState, selection) {
        case (.idle, _), (.loading, _):
            ProgressView().controlSize(.small)
        case (.failed(let err), _):
            ContentUnavailableView(
                "Couldn't load profiles",
                systemImage: "exclamationmark.triangle",
                description: Text(err.localizedDescription)
            )
        case (.loaded, .none):
            ContentUnavailableView("Select a profile or session", systemImage: "sidebar.leading")
        case (.loaded, .profile(let name)):
            if let node = profilesModel.findProfile(named: name) {
                ProfileDetailView(node: node, sidebarSelection: $selection)
            } else {
                ContentUnavailableView("Profile not found", systemImage: "questionmark.circle")
            }
        case (.loaded, .session(let name)):
            if let node = profilesModel.findSession(named: name) {
                SessionDetailView(node: node)
            } else {
                ContentUnavailableView("Session not found", systemImage: "questionmark.circle")
            }
        }
    }
}

#Preview("Detail – loaded, no selection") {
    DetailViewPreviewHarness(selection: nil)
}

#Preview("Detail – loaded, profile selected") {
    DetailViewPreviewHarness(selection: .profile(name: "default"))
}

#Preview("Detail – Read Only mode") {
    DetailViewPreviewHarness(
        selection: .profile(name: "default"),
        mode: .readOnly
    )
}

private struct DetailViewPreviewHarness: View {
    let initialSelection: SidebarSelection?
    let mode: ManagedMode
    @State private var selection: SidebarSelection?
    @State private var appModel: AppModel
    @State private var profilesModel = ProfilesModel()

    init(selection: SidebarSelection?, mode: ManagedMode = .managed) {
        self.initialSelection = selection
        self.mode = mode
        let tmp = URL(filePath: "/nonexistent/aws-folder")
        _appModel = State(initialValue: AppModel(initialPhase: .ready(tmp), initialMode: mode))
        _selection = State(initialValue: selection)
    }

    var body: some View {
        DetailView(selection: $selection)
            .environment(appModel)
            .environment(profilesModel)
            .task {
                let tmp = FileManager.default.temporaryDirectory
                    .appending(path: UUID().uuidString, directoryHint: .isDirectory)
                try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                try? sampleConfig.write(
                    to: tmp.appending(path: "config", directoryHint: .notDirectory),
                    atomically: true,
                    encoding: .utf8
                )
                appModel = AppModel(initialPhase: .ready(tmp), initialMode: mode)
                await profilesModel.load(folder: tmp)
                if let initialSelection {
                    selection = initialSelection
                }
            }
    }

    private var sampleConfig: String {
        """
        [sso-session acme]
        sso_start_url = https://acme.awsapps.com/start
        sso_region = us-east-1
        sso_registration_scopes = sso:account:access

        [default]
        sso_session = acme
        sso_account_id = 412903117204
        sso_role_name = AdministratorAccess
        region = us-east-1
        output = json

        [profile assume-billing]
        role_arn = arn:aws:iam::412903117204:role/Billing
        source_profile = default
        """
    }
}
