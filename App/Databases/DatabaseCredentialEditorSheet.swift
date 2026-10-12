import DatabaseProxy
import QuorraAppLogic
import SwiftData
import SwiftUI

/// Adds or edits a saved database credential. The password goes straight to the Keychain;
/// leaving it empty while editing keeps the current one.
struct DatabaseCredentialEditorSheet: View {
    let existing: DatabaseCredentialDefinition?
    let onSave: (DatabaseCredentialDefinition) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(DatabaseModel.self) private var databaseModel
    @State private var name: String
    @State private var username: String
    @State private var password = ""
    @State private var validationMessage: String?
    @State private var isSaving = false

    init(existing: DatabaseCredentialDefinition?, onSave: @escaping (DatabaseCredentialDefinition) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _username = State(initialValue: existing?.username ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(existing.map { "Edit \($0.name)" } ?? "Add Database Credential")
                .font(.title3.weight(.semibold))

            Form {
                TextField("Name", text: $name)
                TextField("Database username", text: $username)
                SecureField(existing == nil ? "Password" : "New password", text: $password,
                            prompt: existing == nil ? nil : Text("Unchanged"))
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
                Button(existing == nil ? "Add" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func save() {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let saved = try await DatabaseStore.saveCredential(
                    existing, name: name, username: username, password: password.isEmpty ? nil : password,
                    secrets: databaseModel.secrets, in: modelContext
                )
                onSave(saved)
                dismiss()
            } catch {
                validationMessage = error.localizedDescription
            }
        }
    }
}
