import AppKit
import ClientVPN
import QuorraAppLogic
import SwiftData
import SwiftUI

/// A saved Client VPN: its connection and actions, the server it reaches, the tunnel's routes
/// while connected, and the databases that use it.
struct ClientVPNDetailView: View {
    let profile: ClientVPNProfileDefinition
    @Binding var detailSelection: DetailSelection?

    @Environment(ClientVPNController.self) private var controller
    @Environment(\.clientVPNSecrets) private var secrets
    @Query private var profiles: [ClientVPNProfileDefinition]
    @State private var isEditing = false
    @State private var actionMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                statusCard
                endpointCard
                if status == .connected, let tunnel = controller.tunnel {
                    routingCard(tunnel)
                }
                usedByCard
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $isEditing) {
            ClientVPNEditorSheet(mode: .edit(profile)) { _ in }
        }
    }

    private var status: ClientVPNStatus { controller.status(for: profile.stableID) }
    private var savedSignIn: Date? { controller.savedSignIn(for: profile.stableID) }

    /// The profile holding the one VPN macOS allows, when it isn't this one.
    private var otherName: String? {
        guard status == .blocked else { return nil }
        return profiles.first { $0.stableID == controller.profileID }?.name ?? "Another VPN"
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(profile.name)
                .font(.largeTitle.weight(.bold))
                .lineLimit(1)
            Button {
                profile.isFavorite.toggle()
            } label: {
                Image(systemName: profile.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(profile.isFavorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(profile.isFavorite ? "Remove from favourites" : "Add to favourites")
            .accessibilityLabel(profile.isFavorite ? "Remove from favourites" : "Add to favourites")
            Spacer()
            Button("Edit") { isEditing = true }
        }
    }

    private var statusCard: some View {
        DetailCard("Status") {
            VStack(alignment: .leading, spacing: 10) {
                Label(status.title, systemImage: status.systemImage)
                    .foregroundStyle(status.tint)
                    .font(.callout.weight(.semibold))
                if status == .connected {
                    if let address = controller.tunnel?.address {
                        Text(address)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    if let connectedDate = controller.connectedDate {
                        Text("Connected for \(Text(connectedDate, style: .relative))")
                            .foregroundStyle(.secondary)
                    }
                }
                if status == .signingIn {
                    Text("Finish signing in in your browser.")
                        .foregroundStyle(.secondary)
                }
                if let failure = status.failure {
                    Label(failure.localizedDescription, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if let actionMessage {
                    Label(actionMessage, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if !status.isActive, let savedSignIn {
                    Text("Your browser sign-in from \(Text(savedSignIn, style: .time)) is still saved, so Connect won't open the browser.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                actions
            }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            switch status {
            case .connected:
                Button("Disconnect", role: .destructive) { disconnect() }
                if let address = controller.tunnel?.address {
                    Button("Copy IP Address") { copy(address) }
                }
            case .connecting, .signingIn:
                Button("Cancel") { disconnect() }
            case .disconnecting:
                ProgressView()
                    .controlSize(.small)
            case .disconnected, .blocked, .dropped, .failed:
                Button("Connect") { connect(signInAgain: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(otherName != nil)
                    .help(otherName.map { "Disconnect \($0) first. macOS runs one VPN at a time." } ?? "Connect this VPN")
                if savedSignIn != nil {
                    Button("Sign In Again…") { connect(signInAgain: true) }
                        .disabled(otherName != nil)
                }
            }
        }
    }

    private var endpointCard: some View {
        DetailCard("Endpoint") {
            DetailField("Server") { Text(profile.endpoint).monospaced().textSelection(.enabled) }
            DetailDivider()
            DetailField("Protocol") { Text(verbatim: "\(profile.transport.rawValue) \(profile.port)") }
            DetailDivider()
            DetailField("Sign-in") { Text(profile.usesBrowserSignIn ? "SAML in your browser" : "Client certificate") }
            DetailDivider()
            DetailField("Profile") { Text("Imported from \(profile.fileName)") }
        }
    }

    private func routingCard(_ tunnel: ClientVPNTunnelSettings) -> some View {
        DetailCard("Routing") {
            DetailField("Routes") {
                if tunnel.routesAllTraffic {
                    Text("All traffic")
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(tunnel.routes, id: \.self) { route in
                            Text(route).monospaced().textSelection(.enabled)
                        }
                        if tunnel.omittedRoutes > 0 {
                            Text("and \(tunnel.omittedRoutes) more")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            DetailDivider()
            DetailField("DNS") {
                Text(tunnel.dnsServers.isEmpty ? "Your network's DNS servers" : tunnel.dnsServers.joined(separator: ", "))
                    .monospaced(!tunnel.dnsServers.isEmpty)
                    .textSelection(.enabled)
            }
            DetailDivider()
            DetailField("Traffic") {
                Text(tunnel.routesAllTraffic ? "All traffic goes through the VPN" : "Only these routes go through the VPN")
            }
        }
    }

    private var usedByCard: some View {
        DetailCard("Used by") {
            if profile.connections.isEmpty {
                Text("No databases use this VPN.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(profile.connections.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, id: \.stableIDString) { connection in
                    Button(connection.name) {
                        detailSelection = .databaseConnection(id: connection.stableIDString)
                    }
                    .buttonStyle(.link)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func connect(signInAgain: Bool) {
        actionMessage = nil
        Task {
            do {
                try await controller.connect(profile, secrets: secrets, signInAgain: signInAgain)
            } catch {
                actionMessage = error.localizedDescription
            }
        }
    }

    private func disconnect() {
        Task { await controller.disconnect() }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
