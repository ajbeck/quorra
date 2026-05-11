import SwiftUI

struct MainView: View {
    let folderURL: URL
    @Environment(AppModel.self) private var appModel
    @Environment(ProfilesModel.self) private var profilesModel
    @State private var selection: SidebarSelection? = nil

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            DetailView(selection: $selection)
        }
        .toolbar { toolbarContent }
        .task(id: folderURL) {
            await profilesModel.load(folder: folderURL)
        }
        .onChange(of: profilesModel.loadState) { _, newState in
            guard newState == .loaded, selection == nil else { return }
            let groups = profilesModel.groups
            if let firstSession = groups.ssoSessions.first, let firstProfile = firstSession.profiles.first {
                selection = .profile(name: firstProfile.id)
            } else if let firstLTK = groups.longTermKeys.first {
                selection = .profile(name: firstLTK.id)
            } else if let firstOther = groups.other.first {
                selection = .profile(name: firstOther.id)
            }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await profilesModel.reload() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command])
        }
    }
}

#Preview("Main – empty folder") {
    let folderURL = URL(filePath: "/nonexistent/aws-folder")
    MainView(folderURL: folderURL)
        .environment(AppModel(initialPhase: .ready(folderURL)))
        .environment(ProfilesModel())
}

#Preview("Main – with sample data") {
    MainViewSampleDataHarness()
}

private struct MainViewSampleDataHarness: View {
    @State private var folderURL: URL?
    @State private var appModel = AppModel(initialPhase: .setup)
    @State private var profilesModel = ProfilesModel()

    var body: some View {
        Group {
            if let folderURL {
                MainView(folderURL: folderURL)
                    .environment(appModel)
                    .environment(profilesModel)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task {
            let tmp = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            try? sampleConfig.write(
                to: tmp.appending(path: "config", directoryHint: .notDirectory),
                atomically: true,
                encoding: .utf8
            )
            try? sampleCredentials.write(
                to: tmp.appending(path: "credentials", directoryHint: .notDirectory),
                atomically: true,
                encoding: .utf8
            )
            appModel = AppModel(initialPhase: .ready(tmp))
            folderURL = tmp
        }
    }

    private var sampleConfig: String {
        """
        [sso-session acme]
        sso_start_url = https://acme.awsapps.com/start
        sso_region = us-east-1
        sso_registration_scopes = sso:account:access

        [sso-session blueriver]
        sso_start_url = https://blueriver.awsapps.com/start
        sso_region = eu-west-1

        [default]
        sso_session = acme
        sso_account_id = 412903117204
        sso_role_name = AdministratorAccess
        region = us-east-1
        output = json

        [profile acme-prod-admin]
        sso_session = acme
        sso_account_id = 412903117204
        sso_role_name = AdministratorAccess
        region = us-east-1

        [profile acme-prod-readonly]
        sso_session = acme
        sso_account_id = 412903117204
        sso_role_name = ReadOnlyAccess
        region = us-east-1

        [profile blueriver-dev]
        sso_session = blueriver
        sso_account_id = 928104400211
        sso_role_name = DeveloperAccess
        region = eu-west-1

        [profile assume-billing]
        role_arn = arn:aws:iam::412903117204:role/Billing
        source_profile = default
        """
    }

    private var sampleCredentials: String {
        """
        [ci-deploy]
        aws_access_key_id = AKIAIOSFODNN7EXAMPLE
        aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

        [homelab-backup]
        aws_access_key_id = AKIAJK4OOIK4OOIK4OOI
        aws_secret_access_key = SECRET-DO-NOT-USE-THIS-EXAMPLE-KEY
        """
    }
}
