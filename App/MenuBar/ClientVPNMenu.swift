import AppKit
import ClientVPN
import QuorraAppLogic
import SwiftUI

/// One saved Client VPN in the menu bar: its state in the title, its actions in a submenu.
/// A menu cannot show an error, so a Connect that fails before the tunnel starts opens the VPN
/// in the main window.
struct ClientVPNMenu: View {
    let profile: ClientVPNProfileDefinition
    let controller: ClientVPNController
    let secrets: ClientVPNProfileSecrets
    /// The profile holding the one VPN macOS runs, when it isn't this one.
    let otherName: String?
    let showInQuorra: (DetailSelection) -> Void

    var body: some View {
        Menu {
            Text(statusLine)

            switch status {
            case .connected:
                Button("Disconnect") { disconnect() }
                if let address {
                    Button("Copy IP Address") { copy(address) }
                }
            case .connecting, .signingIn:
                Button("Cancel") { disconnect() }
            case .disconnecting:
                EmptyView()
            case .disconnected, .blocked, .dropped, .failed:
                Button("Connect") { connect(signInAgain: false) }
                    .disabled(otherName != nil)
                if controller.savedSignIn(for: profile.stableID) != nil {
                    Button("Sign In Again…") { connect(signInAgain: true) }
                        .disabled(otherName != nil)
                }
            }

            Divider()

            Button("Show in Quorra…") {
                showInQuorra(selection)
            }
        } label: {
            Label(menuTitle(title), systemImage: status.systemImage)
                .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel("\(profile.name), \(statusLine)")
    }

    private var status: ClientVPNStatus {
        controller.status(for: profile.stableID)
    }

    private var selection: DetailSelection {
        .clientVPN(id: profile.stableIDString)
    }

    private var address: String? {
        controller.tunnel?.address
    }

    /// The name, followed by what the VPN is doing when that isn't Disconnected.
    private var title: String {
        switch status {
        case .connected: address.map { "\(profile.name) · \($0)" } ?? profile.name
        case .signingIn: "\(profile.name) · Sign in"
        case .connecting, .disconnecting, .dropped, .failed: "\(profile.name) · \(status.title)"
        case .disconnected, .blocked: profile.name
        }
    }

    private var statusLine: String {
        switch status {
        case .connected:
            guard let connectedDate = controller.connectedDate else { return status.title }
            return "Connected for \(Duration.seconds(max(Date.now.timeIntervalSince(connectedDate), 60)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))"
        case .signingIn:
            return "Finish in your browser"
        case .blocked:
            return "Disconnect \(otherName ?? "the other VPN") first"
        case .dropped(let failure), .failed(let failure):
            return failure.localizedDescription
        case .disconnected, .connecting, .disconnecting:
            return status.title
        }
    }

    private func connect(signInAgain: Bool) {
        Task {
            do {
                try await controller.connect(profile, secrets: secrets, signInAgain: signInAgain)
            } catch {
                showInQuorra(selection)
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
