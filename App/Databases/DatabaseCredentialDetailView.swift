import QuorraAppLogic
import SwiftData
import SwiftUI

/// A saved database credential and the connections that use it. The password stays in the
/// Keychain and is never shown.
struct DatabaseCredentialDetailView: View {
    let credential: DatabaseCredentialDefinition
    @Binding var detailSelection: DetailSelection?
    @State private var isEditing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(credential.name)
                        .font(.largeTitle.weight(.bold))
                        .lineLimit(1)
                    Spacer()
                    Button("Edit") { isEditing = true }
                }
                DetailCard("Credential") {
                    DetailField("Username") { Text(credential.username).monospaced().textSelection(.enabled) }
                    DetailDivider()
                    DetailField("Password") { Text("Saved in the Keychain").foregroundStyle(.secondary) }
                }
                DetailCard("Used by") {
                    if credential.connections.isEmpty {
                        Text("No connections use this credential.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(credential.connections.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, id: \.stableIDString) { connection in
                            Button(connection.name) {
                                detailSelection = .databaseConnection(id: connection.stableIDString)
                            }
                            .buttonStyle(.link)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $isEditing) {
            DatabaseCredentialEditorSheet(existing: credential) { _ in }
        }
    }
}
