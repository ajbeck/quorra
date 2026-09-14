import SwiftUI
import QuorraAppLogic

/// Creates an IAM Identity Center session in the store. Sign-in happens from the session's detail view.
struct AddSessionSheet: View {
    let existingNames: Set<String>
    let onCreate: (SessionDefinition) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var draft = SessionDraft()
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Session")
                .font(.title3.weight(.semibold))

            Form {
                TextField("Name", text: $name, prompt: Text("my-org"))
                TextField("Start URL", text: $draft.startURL, prompt: Text("https://my-domain.awsapps.com/start"))
                    .fontDesign(.monospaced)
                TextField("Region", text: $draft.region, prompt: Text("us-east-1"))
                    .fontDesign(.monospaced)
                TextField("Scopes", text: scopesText, prompt: Text("sso:account:access"))
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
                Button("Add") { add() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private var scopesText: Binding<String> {
        Binding(
            get: { draft.registrationScopes.joined(separator: ", ") },
            set: { draft.registrationScopes = Self.scopes(from: $0) }
        )
    }

    private func add() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "Session name is required."
            return
        }
        guard !existingNames.contains(trimmedName) else {
            validationMessage = "A session named \(trimmedName) already exists."
            return
        }
        if let message = draft.validationMessage {
            validationMessage = message
            return
        }

        do {
            try onCreate(SessionDefinition(
                name: trimmedName,
                startURL: draft.trimmedStartURL,
                region: draft.trimmedRegion,
                registrationScopes: draft.resolvedScopes
            ))
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    static func scopes(from text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

#if DEBUG

#Preview("Add Session") {
    AddSessionSheet(existingNames: ["astrocompute"]) { _ in }
}

#endif
