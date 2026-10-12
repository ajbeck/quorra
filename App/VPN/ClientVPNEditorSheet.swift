import QuorraAppLogic
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Adds an imported `.ovpn` profile, or edits a saved one's name, server and file. The profile
/// text goes straight to the Keychain.
struct ClientVPNEditorSheet: View {
    enum Mode {
        case add(ClientVPNProfile, fileName: String)
        case edit(ClientVPNProfileDefinition)
    }

    let mode: Mode
    let onSave: (ClientVPNProfileDefinition) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.clientVPNSecrets) private var secrets
    @Environment(ClientVPNController.self) private var controller
    @State private var name: String
    @State private var endpoint: String
    @State private var replacement: (profile: ClientVPNProfile, fileName: String)?
    @State private var isChoosingFile = false
    @State private var validationMessage: String?
    @State private var isSaving = false

    init(mode: Mode, onSave: @escaping (ClientVPNProfileDefinition) -> Void) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .add(let profile, let fileName):
            _name = State(initialValue: (fileName as NSString).deletingPathExtension)
            _endpoint = State(initialValue: profile.endpoint)
        case .edit(let definition):
            _name = State(initialValue: definition.name)
            _endpoint = State(initialValue: definition.endpoint)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if case .add(_, let fileName) = mode {
                    Text("Read from \(fileName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Form {
                TextField("Name", text: $name)
                TextField("Server", text: $endpoint)
                    .monospaced()
                if case .edit = mode {
                    LabeledContent("Profile") {
                        HStack {
                            Text(fileName)
                            Button("Replace…") { isChoosingFile = true }
                                .controlSize(.small)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(isAdding ? "Add" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
        }
        .padding(24)
        .frame(width: 460)
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.openVPNProfile]) { result in
            Task {
                do {
                    let url = try result.get()
                    replacement = (try await ClientVPNProfile.load(from: url), url.lastPathComponent)
                    if let replacement, case .edit(let definition) = mode, endpoint == definition.profileEndpoint {
                        endpoint = replacement.profile.endpoint
                    }
                    validationMessage = nil
                } catch {
                    validationMessage = error.localizedDescription
                }
            }
        }
    }

    private var isAdding: Bool {
        if case .add = mode { true } else { false }
    }

    private var title: String {
        switch mode {
        case .add: "Add Client VPN"
        case .edit(let definition): "Edit \(definition.name)"
        }
    }

    private var fileName: String {
        if let replacement { return replacement.fileName }
        if case .edit(let definition) = mode { return definition.fileName }
        return ""
    }

    /// The server named in the profile file the sheet will save.
    private var profileEndpoint: String {
        if let replacement { return replacement.profile.endpoint }
        switch mode {
        case .add(let profile, _): return profile.endpoint
        case .edit(let definition): return definition.profileEndpoint
        }
    }

    private var note: String {
        if isAdding {
            return "The profile, including any client certificate and key, is saved in the Keychain. You can delete the file afterwards."
        }
        let server = endpoint.trimmingCharacters(in: .whitespacesAndNewlines) == profileEndpoint
            ? ""
            : "The profile's server is \(profileEndpoint). Quorra connects to the server above instead. "
        return server + "Changes apply the next time you connect."
    }

    private func save() {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                switch mode {
                case .add(let profile, let fileName):
                    let saved = try await ClientVPNProfileStore.add(profile, fileName: fileName, name: name, endpoint: endpoint, secrets: secrets, in: modelContext)
                    onSave(saved)
                case .edit(let definition):
                    try await saveEdit(definition)
                    onSave(definition)
                }
                dismiss()
            } catch {
                validationMessage = error.localizedDescription
            }
        }
    }

    private func saveEdit(_ definition: ClientVPNProfileDefinition) async throws {
        let id = definition.stableID
        let newEndpoint = try ClientVPNProfile.endpoint(from: endpoint)
        let changesConnection = replacement != nil || newEndpoint != definition.endpoint
        if changesConnection, controller.status(for: id).isActive {
            throw EditError.connected(definition.name)
        }
        // The name is checked before the file is replaced. The sheet already moved an endpoint that
        // followed the old file to the new one, so the replacement keeps what is saved here.
        try ClientVPNProfileStore.save(definition, name: name, endpoint: newEndpoint, in: modelContext)
        if let replacement {
            try await ClientVPNProfileStore.replaceProfile(of: definition, with: replacement.profile, fileName: replacement.fileName, secrets: secrets, in: modelContext)
        }
        // The saved sign-in belongs to the old server and file.
        if changesConnection { controller.forgetSignIn(for: id) }
    }

    private enum EditError: LocalizedError {
        case connected(String)

        var errorDescription: String? {
            switch self {
            case .connected(let name): "Disconnect \(name) before changing its server or profile."
            }
        }
    }
}

extension UTType {
    /// OpenVPN configuration files; AWS Client VPN exports them as `.ovpn`.
    static let openVPNProfile = UTType(filenameExtension: "ovpn", conformingTo: .data) ?? .data
}
