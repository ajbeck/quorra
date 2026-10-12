import AppKit
import DatabaseProxy
import QuorraAppLogic
import SwiftData
import SwiftUI

/// A database connection: its live status and actions, what a local client needs to connect,
/// the upstream it relays to, and its event log.
struct DatabaseConnectionDetailView: View {
    let connection: DatabaseConnectionDefinition

    @Environment(DatabaseModel.self) private var databaseModel
    @State private var isEditing = false
    @State private var actionMessage: String?
    @State private var localPassword: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                statusCard
                clientCard
                upstreamCard
                DatabaseConnectionLogCard(connectionID: connection.stableIDString)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $isEditing) {
            DatabaseConnectionEditorSheet(existing: connection) { _ in }
        }
        .task(id: connection.localAuthenticationRawValue) {
            guard draft.localAuthentication == .generatedPassword else { localPassword = nil; return }
            localPassword = try? await databaseModel.localPassword(for: connection)
        }
    }

    private var draft: DatabaseConnectionDraft { connection.draft }
    private var status: ProxyEndpointStatus { databaseModel.status(for: connection.stableID) }
    private var isWorking: Bool { databaseModel.workingConnectionIDs.contains(connection.stableID) }

    private var header: some View {
        HStack(spacing: 12) {
            Text(connection.name)
                .font(.largeTitle.weight(.bold))
                .lineLimit(1)
            Button {
                connection.isFavorite.toggle()
            } label: {
                Image(systemName: connection.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(connection.isFavorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(connection.isFavorite ? "Remove from favourites" : "Add to favourites")
            .accessibilityLabel(connection.isFavorite ? "Remove from favourites" : "Add to favourites")
            Spacer()
            Button("Edit") { isEditing = true }
                .disabled(status.state.isRunning)
                .help(status.state.isRunning ? "Stop the connection before editing it." : "Edit this connection")
        }
    }

    private var statusCard: some View {
        DetailCard("Status") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label(status.state.rawValue, systemImage: status.state.systemImage)
                        .foregroundStyle(status.state.tint)
                        .font(.callout.weight(.semibold))
                    if status.state == .listening {
                        Text("\(status.activeConnections) \(status.activeConnections == 1 ? "client" : "clients")")
                            .foregroundStyle(.secondary)
                    }
                }
                if let url = draft.localURL {
                    Text(url)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                if let issue = status.issue ?? actionMessage {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(status.state == .failed ? Color.red : Color.secondary)
                }
                HStack(spacing: 8) {
                    if status.state.isRunning {
                        Button("Stop", role: .destructive) {
                            Task { await databaseModel.stop(connection.stableID) }
                        }
                    } else {
                        Button("Start") { run(start: true) }
                            .buttonStyle(.borderedProminent)
                        Button("Test Connection") { run(start: false) }
                    }
                    if let url = draft.localURL {
                        Button("Copy URL") { copy(url) }
                    }
                }
                .disabled(isWorking)
            }
        }
    }

    private var clientCard: some View {
        DetailCard("Connect your client") {
            DetailField("Host") { Text("127.0.0.1").monospaced().textSelection(.enabled) }
            DetailDivider()
            DetailField("Port") { Text(verbatim: "\(draft.localPort)").monospaced().textSelection(.enabled) }
            DetailDivider()
            DetailField("User") { Text(DatabaseConnectionDraft.localUsername).monospaced().textSelection(.enabled) }
            DetailDivider()
            DetailField("Database") { Text(draft.database).monospaced().textSelection(.enabled) }
            DetailDivider()
            DetailField("Password") {
                if let localPassword {
                    HStack {
                        Text("••••••••••••").monospaced()
                        Button("Copy") { copy(localPassword) }
                            .controlSize(.small)
                    }
                } else {
                    Text("None; Quorra trusts clients on this Mac").foregroundStyle(.secondary)
                }
            }
            DetailDivider()
            DetailField("Command") {
                HStack(alignment: .firstTextBaseline) {
                    Text(clientCommand)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    Button("Copy") { copy(clientCommand) }
                        .controlSize(.small)
                }
            }
        }
    }

    private var upstreamCard: some View {
        DetailCard("Upstream") {
            DetailField("Server") { Text(draft.upstreamAddress).monospaced().textSelection(.enabled) }
            DetailDivider()
            DetailField("Authentication") {
                if draft.authentication == .awsIAM {
                    Text("AWS IAM as \(draft.username) · profile \(connection.profile?.name ?? "none")")
                } else {
                    Text("Password · \(connection.credential?.name ?? "no credential")")
                }
            }
            DetailDivider()
            DetailField("TLS") {
                Text(draft.tlsMode == .verified ? "Verified · \(draft.trust.title)" : "Off")
            }
        }
    }

    private var clientCommand: String {
        let base: String
        if draft.engine == .postgresql {
            base = "psql \"host=127.0.0.1 port=\(draft.localPort) dbname=\(draft.database) user=\(DatabaseConnectionDraft.localUsername) sslmode=disable\""
        } else {
            base = "mysql --host=127.0.0.1 --port=\(draft.localPort) --user=\(DatabaseConnectionDraft.localUsername) --ssl-mode=DISABLED \(draft.database)"
        }
        guard localPassword != nil else { return base }
        return base + (draft.engine == .postgresql ? " -W" : " -p")
    }

    private func run(start: Bool) {
        actionMessage = nil
        Task {
            do {
                if start {
                    try await databaseModel.start(connection)
                } else {
                    try await databaseModel.test(connection)
                    actionMessage = draft.tlsMode == .verified
                        ? "Verified TLS and database sign-in succeeded."
                        : "Database sign-in succeeded. Upstream TLS is off."
                }
            } catch is CancellationError {
            } catch {
                actionMessage = ProxyCoordinator.message(error)
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

/// The newest proxy events for one connection, from Quorra's store.
private struct DatabaseConnectionLogCard: View {
    @Query private var entries: [DatabaseConnectionLogEntry]

    init(connectionID: String) {
        var descriptor = FetchDescriptor<DatabaseConnectionLogEntry>(
            predicate: #Predicate { $0.connectionIDString == connectionID },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 50
        _entries = Query(descriptor)
    }

    var body: some View {
        DetailCard("Log") {
            if entries.isEmpty {
                ContentUnavailableView("No Events", systemImage: "list.bullet.rectangle",
                                       description: Text("Start or test the connection to see its events here."))
                    .frame(maxWidth: .infinity, minHeight: 92)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries, id: \.stableIDString) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 86, alignment: .leading)
                            Image(systemName: entry.level == "error" ? "xmark.octagon.fill" : entry.level == "warning" ? "exclamationmark.triangle.fill" : "circle.fill")
                                .font(.caption2)
                                .foregroundStyle(entry.level == "error" ? Color.red : entry.level == "warning" ? Color.orange : Color.secondary)
                            Text(Self.title(entry.event))
                            if let failureCode = entry.failureCode {
                                Text(failureCode)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if let client = entry.clientIDString {
                                Text("client \(client.prefix(8))")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        if entry.stableIDString != entries.last?.stableIDString {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    /// `endpointCheckingUpstream` reads as "Endpoint checking upstream".
    static func title(_ event: String) -> String {
        let words = event.replacing(/([a-z])([A-Z])/) { "\($0.output.1) \($0.output.2.lowercased())" }
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
