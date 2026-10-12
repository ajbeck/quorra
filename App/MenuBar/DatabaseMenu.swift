import AppKit
import DatabaseProxy
import QuorraAppLogic
import SwiftUI

/// One database connection in the menu bar: its state in the title, its actions in a submenu.
/// A menu cannot show an error, so a failed Start opens the connection in the main window.
struct DatabaseMenu: View {
    let connection: DatabaseConnectionDefinition
    let databaseModel: DatabaseModel
    /// The connected VPN that keeps this connection's own VPN from connecting.
    let blockingVPNName: String?
    let showInQuorra: (DetailSelection) -> Void

    var body: some View {
        Menu {
            Text(statusLine)

            if status.state.isRunning {
                Button("Stop") {
                    Task { await databaseModel.stop(connection.stableID) }
                }
            } else {
                Button("Start") {
                    Task {
                        do {
                            try await databaseModel.start(connection)
                        } catch {
                            showInQuorra(selection)
                        }
                    }
                }
                .disabled(databaseModel.workingConnectionIDs.contains(connection.stableID) || blockingVPNName != nil)
            }

            Divider()

            if let url = connection.draft.localURL {
                Button("Copy URL") { copy(url) }
            }
            if connection.draft.localAuthentication == .generatedPassword {
                Button("Copy Password") {
                    Task {
                        if let password = try? await databaseModel.localPassword(for: connection) { copy(password) }
                    }
                }
            }

            Button("Show in Quorra…") {
                showInQuorra(selection)
            }
        } label: {
            Label(menuTitle(title), systemImage: status.state.systemImage)
                .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel("\(title), \(statusLine)")
    }

    private var status: ProxyEndpointStatus {
        databaseModel.status(for: connection.stableID)
    }

    private var selection: DetailSelection {
        .databaseConnection(id: connection.stableIDString)
    }

    private var title: String {
        "\(connection.name) · :\(connection.localPort)"
    }

    private var statusLine: String {
        switch status.state {
        case .listening:
            return "Listening · \(status.activeConnections) \(status.activeConnections == 1 ? "client" : "clients")"
        case .failed:
            return "Needs attention"
        case .starting, .checkingUpstream:
            return "Starting…"
        case .stopped:
            if let blockingVPNName {
                return "Off · Disconnect \(blockingVPNName) first"
            }
            return "Off"
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
