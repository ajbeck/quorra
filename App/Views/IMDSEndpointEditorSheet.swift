import SwiftUI
import QuorraAppLogic

struct IMDSEndpointEditorDraft {
    var name: String
    var profileName: String
    var port: Int
    var bindAddress: String
    var allowsIMDSv1: Bool
    var hopLimit: Int

    init(
        name: String,
        profileName: String,
        port: Int,
        bindAddress: String,
        allowsIMDSv1: Bool,
        hopLimit: Int
    ) {
        self.name = name
        self.profileName = profileName
        self.port = port
        self.bindAddress = bindAddress
        self.allowsIMDSv1 = allowsIMDSv1
        self.hopLimit = hopLimit
    }

    init(endpoint: IMDSEndpointDefinition) {
        self.init(
            name: endpoint.name,
            profileName: endpoint.profileName,
            port: endpoint.port,
            bindAddress: endpoint.bindAddress,
            allowsIMDSv1: endpoint.allowsIMDSv1,
            hopLimit: endpoint.hopLimit
        )
    }

    func makeEndpoint() -> IMDSEndpointDefinition {
        IMDSEndpointDefinition(
            name: name,
            profileName: profileName,
            port: port,
            bindAddress: bindAddress,
            allowsIMDSv1: allowsIMDSv1,
            hopLimit: hopLimit
        )
    }

    func apply(to endpoint: IMDSEndpointDefinition) {
        endpoint.name = name
        endpoint.profileName = profileName
        endpoint.port = port
        endpoint.bindAddress = bindAddress
        endpoint.allowsIMDSv1 = allowsIMDSv1
        endpoint.hopLimit = hopLimit
        endpoint.updatedAt = .now
    }
}

struct IMDSEndpointEditorSheet: View {
    enum Mode {
        case create
        case edit

        var title: String {
            switch self {
            case .create:
                return "Add IMDS Endpoint"
            case .edit:
                return "Edit IMDS Endpoint"
            }
        }

        var actionTitle: String {
            switch self {
            case .create:
                return "Add"
            case .edit:
                return "Save"
            }
        }
    }

    let mode: Mode
    let existingNames: Set<String>
    let usedPorts: Set<Int>
    let profiles: [ProfileNode]
    let initialDraft: IMDSEndpointEditorDraft
    let onSave: (IMDSEndpointEditorDraft) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: IMDSEndpointEditorDraft
    @State private var originalName: String
    @State private var originalPort: Int
    @State private var validationMessage: String?

    init(
        mode: Mode,
        existingNames: Set<String>,
        usedPorts: Set<Int>,
        profiles: [ProfileNode],
        initialDraft: IMDSEndpointEditorDraft? = nil,
        onSave: @escaping (IMDSEndpointEditorDraft) throws -> Void
    ) {
        self.mode = mode
        self.existingNames = existingNames
        self.usedPorts = usedPorts
        self.profiles = profiles
        self.onSave = onSave

        let resolvedDraft = initialDraft ?? Self.defaultDraft(profiles: profiles, usedPorts: usedPorts)
        self.initialDraft = resolvedDraft
        _draft = State(initialValue: resolvedDraft)
        _originalName = State(initialValue: resolvedDraft.name)
        _originalPort = State(initialValue: resolvedDraft.port)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(mode.title)
                .font(.title3.weight(.semibold))

            Form {
                TextField("Name", text: $draft.name)

                Picker("Profile", selection: $draft.profileName) {
                    ForEach(profiles.sortedByName) { profile in
                        Text(profile.id).tag(profile.id)
                    }
                }

                TextField("Bind address", text: $draft.bindAddress)
                    .fontDesign(.monospaced)

                TextField("Port", value: $draft.port, format: .number.grouping(.never))
                    .fontDesign(.monospaced)

                Toggle("Allow IMDSv1 fallback", isOn: $draft.allowsIMDSv1)

                Stepper(value: $draft.hopLimit, in: 1...64) {
                    Text("Hop limit \(draft.hopLimit)")
                }
            }
            .formStyle(.grouped)
            .onChange(of: draft.profileName) { _, newValue in
                guard draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                draft.name = newValue
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(mode.actionTitle) { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func save() {
        var cleaned = draft
        cleaned.name = cleaned.name.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.bindAddress = cleaned.bindAddress.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.name.isEmpty else {
            validationMessage = "Endpoint name is required."
            return
        }
        guard cleaned.name == originalName || !existingNames.contains(cleaned.name) else {
            validationMessage = "An endpoint named \(cleaned.name) already exists."
            return
        }
        guard !cleaned.profileName.isEmpty else {
            validationMessage = "Select a profile to serve."
            return
        }
        guard !cleaned.bindAddress.isEmpty else {
            validationMessage = "Bind address is required."
            return
        }
        guard (1...65_535).contains(cleaned.port) else {
            validationMessage = "Port must be between 1 and 65535."
            return
        }
        guard cleaned.port == originalPort || !usedPorts.contains(cleaned.port) else {
            validationMessage = "Port \(cleaned.port) is already configured."
            return
        }

        do {
            try onSave(cleaned)
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private static func defaultDraft(profiles: [ProfileNode], usedPorts: Set<Int>) -> IMDSEndpointEditorDraft {
        let firstProfileName = profiles.first?.id ?? ""
        return IMDSEndpointEditorDraft(
            name: firstProfileName,
            profileName: firstProfileName,
            port: firstAvailablePort(from: 9678, usedPorts: usedPorts),
            bindAddress: "127.0.0.1",
            allowsIMDSv1: true,
            hopLimit: 2
        )
    }

    private static func firstAvailablePort(from preferredPort: Int, usedPorts: Set<Int>) -> Int {
        var candidate = preferredPort
        while usedPorts.contains(candidate), candidate < 65_535 {
            candidate += 1
        }
        return candidate
    }
}

extension [ProfileNode] {
    var sortedByName: [ProfileNode] {
        sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}
