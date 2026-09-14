import SwiftUI
import IAMIdentityCenter
import QuorraAppLogic
import SwiftData

/// Creates a profile for one of a session's accounts and roles.
///
/// A signed-in session lists its accounts and roles from the access portal; a signed-out one falls
/// back to typed values. The name defaults to the session, account, and role joined by colons.
struct AddProfileSheet: View {
    let existingNames: Set<String>
    let sessions: [SessionDefinition]
    let onCreate: (ProfileDefinition) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(CredentialsModel.self) private var credentialsModel
    @State private var selectedSessionName: String
    @State private var name = ""
    @State private var region: String
    @State private var accountID = ""
    @State private var roleName = ""
    @State private var accounts: [PortalAccount] = []
    @State private var roles: [PortalRole] = []
    @State private var isLoadingAccounts = false
    @State private var isLoadingRoles = false
    @State private var listingMessage: String?
    @State private var validationMessage: String?

    init(
        existingNames: Set<String>,
        sessions: [SessionDefinition],
        onCreate: @escaping (ProfileDefinition) throws -> Void
    ) {
        self.existingNames = existingNames
        self.sessions = sessions
        self.onCreate = onCreate
        _selectedSessionName = State(initialValue: sessions.first?.name ?? "")
        _region = State(initialValue: sessions.first?.region ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Profile")
                .font(.title3.weight(.semibold))

            Form {
                Picker("Session", selection: $selectedSessionName) {
                    ForEach(sessions, id: \.name) { session in
                        Text(session.name).tag(session.name)
                    }
                }

                Section {
                    accountAndRoleFields
                } header: {
                    Text("Account and role")
                } footer: {
                    if let listingMessage {
                        Text(listingMessage)
                    }
                }

                Section {
                    TextField("Region", text: $region, prompt: Text("us-east-1"))
                        .fontDesign(.monospaced)
                    TextField("Name", text: $name, prompt: Text(suggestedName.isEmpty ? "Name" : suggestedName))
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
            .task(id: selectedSessionName) { await loadAccounts() }
            .task(id: accountID) { await loadRoles() }
            .onChange(of: selectedSessionName) { _, newValue in
                guard region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let session = sessions.first(where: { $0.name == newValue }) else { return }
                region = session.region
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") { add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoadingAccounts || isLoadingRoles)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    @ViewBuilder private var accountAndRoleFields: some View {
        if isLoadingAccounts {
            LabeledContent("Account") {
                ProgressView().controlSize(.small)
            }
        } else if accounts.isEmpty {
            TextField("Account ID", text: $accountID, prompt: Text("123456789012"))
                .fontDesign(.monospaced)
            TextField("Role Name", text: $roleName, prompt: Text("AdministratorAccess"))
        } else {
            Picker("Account", selection: $accountID) {
                Text("Choose an account").tag("")
                ForEach(accounts, id: \.accountId) { account in
                    Text("\(account.accountName) · \(account.accountId)").tag(account.accountId)
                }
            }
            if accountID.isEmpty {
                LabeledContent("Role") {
                    Text("Choose an account first")
                        .foregroundStyle(.secondary)
                }
            } else if isLoadingRoles {
                LabeledContent("Role") {
                    ProgressView().controlSize(.small)
                }
            } else if roles.isEmpty {
                TextField("Role Name", text: $roleName, prompt: Text("AdministratorAccess"))
            } else {
                Picker("Role", selection: $roleName) {
                    Text("Choose a role").tag("")
                    ForEach(roles, id: \.roleName) { role in
                        Text(role.roleName).tag(role.roleName)
                    }
                }
            }
        }
    }

    /// Session, account, and role joined by colons; the portal account name when one was picked.
    private var suggestedName: String {
        let account = accounts.first { $0.accountId == accountID }?.accountName ?? accountID
        let parts = [selectedSessionName, account, roleName].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.allSatisfy({ !$0.isEmpty }) else { return "" }
        return parts.joined(separator: ":").lowercased().replacing(/\s+/, with: "-")
    }

    private func loadAccounts() async {
        accounts = []
        roles = []
        accountID = ""
        roleName = ""
        listingMessage = nil
        guard !selectedSessionName.isEmpty else { return }

        isLoadingAccounts = true
        defer { isLoadingAccounts = false }
        do {
            let listed = try await credentialsModel.accounts(forSession: selectedSessionName)
            guard !Task.isCancelled else { return }
            accounts = listed
            if listed.isEmpty {
                listingMessage = "No accounts are assigned to you in \(selectedSessionName). Enter the account ID and role name."
            }
        } catch is CancellationError {
        } catch IAMIdentityCenterError.notSignedIn, IAMIdentityCenterError.tokenExpired {
            guard !Task.isCancelled else { return }
            listingMessage = "Sign in to \(selectedSessionName) to choose from its accounts and roles, or enter them here."
        } catch {
            guard !Task.isCancelled else { return }
            listingMessage = "Couldn't list accounts: \(error.localizedDescription) Enter the account ID and role name."
        }
    }

    private func loadRoles() async {
        guard !accounts.isEmpty else { return }
        roles = []
        roleName = ""
        guard !accountID.isEmpty else { return }

        isLoadingRoles = true
        defer { isLoadingRoles = false }
        do {
            let listed = try await credentialsModel.roles(forSession: selectedSessionName, accountId: accountID)
            guard !Task.isCancelled else { return }
            roles = listed
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            listingMessage = "Couldn't list roles: \(error.localizedDescription) Enter the role name."
        }
    }

    private func add() {
        guard let session = sessions.first(where: { $0.name == selectedSessionName }) else {
            validationMessage = "Choose a session."
            return
        }
        let account = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let role = roleName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty else {
            validationMessage = "Choose an account or enter its ID."
            return
        }
        guard !role.isEmpty else {
            validationMessage = "Choose a role or enter its name."
            return
        }
        let typedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = typedName.isEmpty ? suggestedName : typedName
        guard !finalName.isEmpty else {
            validationMessage = "Profile name is required."
            return
        }
        guard !existingNames.contains(finalName) else {
            validationMessage = "A profile named \(finalName) already exists."
            return
        }
        let trimmedRegion = region.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try onCreate(ProfileDefinition(
                name: finalName,
                session: session,
                accountID: account,
                roleName: role,
                region: trimmedRegion.isEmpty ? nil : trimmedRegion
            ))
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}

#if DEBUG

#Preview("Add Profile – signed in") {
    AddProfileSheetPreviewHarness(portalListingAvailable: true)
}

#Preview("Add Profile – signed out") {
    AddProfileSheetPreviewHarness(portalListingAvailable: false)
}

private struct AddProfileSheetPreviewHarness: View {
    let portalListingAvailable: Bool
    private let metadataContainer = PreviewIdentityFixtures.makeContainer()

    var body: some View {
        AddProfileSheet(
            existingNames: ["ac:cp:org_admin"],
            sessions: (try? IdentityStore.sessions(in: metadataContainer.mainContext)) ?? []
        ) { _ in }
            .environment(CredentialsModel(service: PreviewIdentityCenterService(portalListingAvailable: portalListingAvailable)))
            .modelContainer(metadataContainer)
    }
}

#endif
