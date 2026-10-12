import DatabaseProxy
import QuorraAppLogic
import SwiftData
import SwiftUI

/// An imported file's settings, matched to a saved profile or credential where exactly one fits.
struct ImportedConnection {
    let draft: DatabaseConnectionDraft
    let profile: ProfileDefinition?
    let credential: DatabaseCredentialDefinition?
    let hint: String
}

/// Adds or edits a database connection: the upstream database, how Quorra signs in to it, and
/// how local clients reach it. The connection must be stopped before it is edited.
struct DatabaseConnectionEditorSheet: View {
    let existing: DatabaseConnectionDefinition?
    let onSave: (DatabaseConnectionDefinition) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [ProfileDefinition]
    @Query private var credentials: [DatabaseCredentialDefinition]
    @Query private var connections: [DatabaseConnectionDefinition]
    @Query(sort: \ClientVPNProfileDefinition.name) private var vpns: [ClientVPNProfileDefinition]
    @State private var draft: DatabaseConnectionDraft
    @State private var profileID: String?
    @State private var credentialID: String?
    @State private var clientVPNID: String?
    @State private var hint: String?
    @State private var validationMessage: String?
    @State private var isAddingCredential = false

    init(existing: DatabaseConnectionDefinition?, imported: ImportedConnection? = nil, onSave: @escaping (DatabaseConnectionDefinition) -> Void) {
        self.existing = existing
        self.onSave = onSave
        let draft = existing?.draft ?? imported?.draft ?? DatabaseConnectionDraft()
        _draft = State(initialValue: draft)
        _profileID = State(initialValue: (existing?.profile ?? imported?.profile)?.stableIDString)
        _credentialID = State(initialValue: (existing?.credential ?? imported?.credential)?.stableIDString)
        _clientVPNID = State(initialValue: existing?.clientVPN?.stableIDString)
        _hint = State(initialValue: imported?.hint)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(existing.map { "Edit \($0.name)" } ?? "Add Database Connection")
                .font(.title3.weight(.semibold))

            Form {
                Section("Database") {
                    TextField("Name", text: $draft.name)
                    Picker("Engine", selection: engine) {
                        ForEach(DatabaseEngine.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Server", text: $draft.host)
                        .fontDesign(.monospaced)
                    TextField("Server port", value: $draft.upstreamPort, format: .number.grouping(.never))
                        .fontDesign(.monospaced)
                    TextField("Database name", text: $draft.database)
                }

                Section("Sign-in") {
                    Picker("Method", selection: authentication) {
                        ForEach(CredentialKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if draft.authentication == .awsIAM {
                        Picker("AWS profile", selection: $profileID) {
                            Text("Choose a profile").tag(String?.none)
                            ForEach(eligibleProfiles, id: \.stableIDString) { Text($0.name).tag(Optional($0.stableIDString)) }
                        }
                        TextField("Database user", text: $draft.username)
                        TextField("Database region", text: $draft.region, prompt: Text("eu-west-2"))
                    } else {
                        Picker("Credential", selection: $credentialID) {
                            Text("Choose a credential").tag(String?.none)
                            ForEach(sortedCredentials, id: \.stableIDString) { Text($0.name).tag(Optional($0.stableIDString)) }
                        }
                        Button("New Credential…") { isAddingCredential = true }
                        Picker("Upstream TLS", selection: $draft.tlsMode) {
                            ForEach(UpstreamTLSMode.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    if draft.tlsMode == .verified {
                        Picker("Verify TLS with", selection: $draft.trust) {
                            ForEach(DatabaseTLSOptions.TrustSource.allCases) { Text($0.title).tag($0) }
                        }
                    }
                }

                Section {
                    Picker("VPN", selection: $clientVPNID) {
                        Text("None").tag(String?.none)
                        ForEach(vpns, id: \.stableIDString) { Text($0.name).tag(Optional($0.stableIDString)) }
                    }
                } header: {
                    Text("Network")
                } footer: {
                    if let vpn = vpns.first(where: { $0.stableIDString == clientVPNID }) {
                        Text("Start connects \(vpn.name) first if it's off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("On this Mac") {
                    TextField("Local port", value: $draft.localPort, format: .number.grouping(.never))
                        .fontDesign(.monospaced)
                    Picker("Client sign-in", selection: $draft.localAuthentication) {
                        ForEach(LocalAuthentication.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)

            if let hint {
                Label(hint, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(existing == nil ? "Add" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            if existing == nil, draft.localPort == DatabaseConnectionDraft().localPort {
                draft.localPort = firstAvailablePort(from: draft.engine.suggestedLocalPort)
            }
        }
        .sheet(isPresented: $isAddingCredential) {
            DatabaseCredentialEditorSheet(existing: nil) { credential in
                credentialID = credential.stableIDString
            }
        }
    }

    /// Switching engines moves default ports along, leaving ports the user typed alone.
    private var engine: Binding<DatabaseEngine> {
        Binding(
            get: { draft.engine },
            set: { newEngine in
                let old = draft.engine
                guard newEngine != old else { return }
                if draft.upstreamPort == old.defaultPort { draft.upstreamPort = newEngine.defaultPort }
                if existing == nil, draft.localPort == firstAvailablePort(from: old.suggestedLocalPort) {
                    draft.localPort = firstAvailablePort(from: newEngine.suggestedLocalPort)
                }
                draft.engine = newEngine
            }
        )
    }

    /// IAM needs verified TLS, so choosing it turns TLS back on.
    private var authentication: Binding<CredentialKind> {
        Binding(
            get: { draft.authentication },
            set: { newValue in
                draft.authentication = newValue
                if newValue == .awsIAM { draft.tlsMode = .verified }
            }
        )
    }

    private var eligibleProfiles: [ProfileDefinition] {
        profiles.filter { $0.session != nil }.sortedByName
    }

    private var sortedCredentials: [DatabaseCredentialDefinition] {
        credentials.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func firstAvailablePort(from preferred: Int) -> Int {
        let used = Set(connections.filter { $0 !== existing }.map(\.localPort))
        var candidate = preferred
        while used.contains(candidate), candidate < 65_535 { candidate += 1 }
        return candidate
    }

    private func save() {
        let profile = profiles.first { $0.stableIDString == profileID }
        let credential = credentials.first { $0.stableIDString == credentialID }
        let clientVPN = vpns.first { $0.stableIDString == clientVPNID }
        do {
            let saved = try DatabaseStore.saveConnection(existing, draft: draft, profile: profile, credential: credential, clientVPN: clientVPN, in: modelContext)
            onSave(saved)
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}
