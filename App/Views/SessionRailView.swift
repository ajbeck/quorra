import SwiftUI
import AWSConfigINI
import IAMIdentityCenter

struct SessionRailView: View {
    @Binding var filter: SessionFilter
    @Binding var selection: DetailSelection?
    @Environment(AppModel.self) private var appModel
    @Environment(ProfilesModel.self) private var profilesModel
    @State private var isPresentingAddSession = false
    @State private var isConfirmingDeleteSession = false
    @State private var actionError: AWSConfigINIError?
    @State private var isPresentingActionError = false

    var body: some View {
        switch profilesModel.loadState {
        case .idle, .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView(
                "Failed to Load Sessions",
                systemImage: "exclamationmark.triangle",
                description: Text("Quorra couldn't read your AWS configuration.")
            )
        case .loaded:
            sessionListContainer
        }
    }

    private var sessionListContainer: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("SSO Sessions")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(sortedSessions.count)")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .textCase(.uppercase)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)

                    sessionButton(
                        for: .all,
                        title: "All Sessions",
                        systemImage: "square.grid.2x2",
                        count: allProfileCount,
                        isAllSessions: true
                    )

                    ForEach(sortedSessions) { session in
                        sessionButton(
                            for: .session(name: session.id),
                            title: session.id,
                            systemImage: "cloud",
                            count: session.profiles.count,
                            isAllSessions: false
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
            Divider()
            sessionMutationBar
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.10))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .frame(maxHeight: .infinity)
        .sheet(isPresented: $isPresentingAddSession) {
            AddSessionSheet(existingNames: Set(sortedSessions.map(\.id))) { name, session in
                try await profilesModel.createSession(named: name, session: session, mode: appModel.mode)
                filter = .session(name: name)
                selection = .session(name: name)
            }
        }
        .confirmationDialog(
            "Delete SSO session?",
            isPresented: $isConfirmingDeleteSession,
            titleVisibility: .visible
        ) {
            if let selectedSessionName {
                Button("Delete \(selectedSessionName)", role: .destructive) {
                    Task { await deleteSession(named: selectedSessionName) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            if let selectedSessionName {
                Text("This removes the [sso-session \(selectedSessionName)] section. Profiles that reference it remain in your config.")
            }
        }
        .alert(
            "Couldn't update sessions",
            isPresented: $isPresentingActionError,
            presenting: actionError
        ) { _ in
            Button("OK", role: .cancel) { }
        } message: { error in
            Text([error.errorDescription, error.recoverySuggestion]
                .compactMap { $0 }.joined(separator: "\n\n"))
        }
    }

    private var sessionMutationBar: some View {
        HStack(spacing: 0) {
            sessionActions
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Color.secondary.opacity(0.10))
    }

    private var sessionActions: some View {
        ControlGroup {
            Button {
                isPresentingAddSession = true
            } label: {
                Label("Add SSO Session", systemImage: "plus")
            }
            .disabled(isReadOnly)
            .help(isReadOnly ? "Switch to Edit & Manage mode to add sessions." : "Add SSO session")

            Button {
                isConfirmingDeleteSession = true
            } label: {
                Label("Remove SSO Session", systemImage: "minus")
            }
            .disabled(isReadOnly || selectedSessionName == nil)
            .help(removeSessionHelp)
        }
        .controlSize(.small)
        .labelStyle(.iconOnly)
    }

    private func sessionButton(
        for candidate: SessionFilter,
        title: String,
        systemImage: String,
        count: Int,
        isAllSessions: Bool
    ) -> some View {
        Button {
            filter = candidate
        } label: {
            SessionRailRow(
                title: title,
                systemImage: systemImage,
                count: count,
                isAllSessions: isAllSessions
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(rowBackground(isSelected: filter == candidate), in: RoundedRectangle(cornerRadius: 6))
    }

    private func rowBackground(isSelected: Bool) -> Color {
        isSelected ? Color.accentColor.opacity(0.18) : Color.clear
    }

    private var sortedSessions: [SSOSessionNode] {
        profilesModel.groups.ssoSessions.sorted {
            $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }

    private var selectedSessionName: String? {
        if case .session(let name) = filter { return name }
        return nil
    }

    private var isReadOnly: Bool {
        appModel.mode == .readOnly
    }

    private var removeSessionHelp: String {
        if isReadOnly { return "Switch to Edit & Manage mode to remove sessions." }
        if selectedSessionName == nil { return "Select a session to remove." }
        return "Remove selected SSO session"
    }

    private var allProfileCount: Int {
        profilesModel.groups.flatProfiles.count
    }

    private func deleteSession(named name: String) async {
        do {
            try await profilesModel.deleteSession(named: name, mode: appModel.mode)
            if selectedSessionName == name {
                filter = .all
            }
            if selection == .session(name: name) {
                selection = nil
            }
        } catch let err as AWSConfigINIError {
            actionError = err
            isPresentingActionError = true
        } catch {
            actionError = .malformedInput(error.localizedDescription)
            isPresentingActionError = true
        }
    }
}

private struct SessionRailRow: View {
    let title: String
    let systemImage: String
    let count: Int
    let isAllSessions: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .symbolRenderingMode(isAllSessions ? .monochrome : .hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)

            Text(title)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text("\(count)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .accessibilityLabel("\(count) profiles")
        }
        .padding(.vertical, 2)
    }
}

private struct AddSessionSheet: View {
    let existingNames: Set<String>
    let onCreate: (String, SSOSession) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var startURL = ""
    @State private var region = ""
    @State private var scopes = "sso:account:access"
    @State private var validationMessage: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add SSO Session")
                .font(.title3.weight(.semibold))

            Form {
                TextField("Name", text: $name)
                TextField("Start URL", text: $startURL)
                TextField("Region", text: $region)
                TextField("Scopes", text: $scopes)
            }
            .formStyle(.grouped)

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") {
                    Task { await add() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func add() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "Session name is required."
            return
        }
        guard !existingNames.contains(trimmedName) else {
            validationMessage = "A session named \(trimmedName) already exists."
            return
        }

        isSaving = true
        validationMessage = nil
        do {
            try await onCreate(
                trimmedName,
                SSOSession(
                    ssoStartUrl: nilIfBlank(startURL),
                    ssoRegion: nilIfBlank(region),
                    ssoRegistrationScopes: scopesList
                )
            )
            dismiss()
        } catch let error as LocalizedError {
            validationMessage = error.errorDescription ?? error.localizedDescription
        } catch {
            validationMessage = error.localizedDescription
        }
        isSaving = false
    }

    private var scopesList: [String]? {
        let values = scopes
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : values
    }

    private func nilIfBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#Preview("SessionRail – populated") {
    SessionRailPreviewHarness()
}

private struct SessionRailPreviewHarness: View {
    @State private var filter: SessionFilter = .all
    @State private var selection: DetailSelection?
    @State private var profilesModel = ProfilesModel.previewLoaded(
        config: PreviewAWSFixtures.mockupConfig,
        credentials: PreviewAWSFixtures.mockupCredentials
    )

    var body: some View {
        NavigationSplitView {
            SessionRailView(filter: $filter, selection: $selection)
        } detail: {
            Text("Detail")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(AppModel(initialPhase: .ready(URL(filePath: "/preview/.aws"))))
        .environment(profilesModel)
        .frame(width: 700, height: 500)
    }
}
