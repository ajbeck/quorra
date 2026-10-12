import ClientVPN
import Foundation
import IAMIdentityCenter
import QuorraAppLogic
import SwiftUI

/// What a saved VPN profile is doing, as the window and menu bar show it.
enum ClientVPNStatus: Hashable {
    case disconnected
    /// Another profile holds the one VPN macOS runs at a time.
    case blocked
    case connecting, signingIn, connected, disconnecting
    /// The tunnel was up and then stopped.
    case dropped(ClientVPNLiveFailure)
    /// The tunnel stopped before it connected.
    case failed(ClientVPNLiveFailure)

    var title: String {
        switch self {
        case .disconnected, .blocked: "Disconnected"
        case .connecting: "Connecting…"
        case .signingIn: "Signing in…"
        case .connected: "Connected"
        case .disconnecting: "Disconnecting…"
        case .dropped: "Dropped"
        case .failed: "Couldn't connect"
        }
    }

    var systemImage: String {
        switch self {
        case .disconnected, .blocked: "circle"
        case .connecting, .signingIn, .disconnecting: "circle.lefthalf.filled"
        case .connected: "circle.fill"
        case .dropped, .failed: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .disconnected, .blocked: .secondary
        case .connecting, .signingIn, .disconnecting: .blue
        case .connected: .green
        case .dropped, .failed: .orange
        }
    }

    var isActive: Bool {
        switch self {
        case .connecting, .signingIn, .connected, .disconnecting: true
        case .disconnected, .blocked, .dropped, .failed: false
        }
    }

    var failure: ClientVPNLiveFailure? {
        switch self {
        case .dropped(let failure), .failed(let failure): failure
        default: nil
        }
    }
}

extension ClientVPNController {
    func status(for id: UUID) -> ClientVPNStatus {
        guard profileID == id else { return isActive ? .blocked : .disconnected }
        switch state {
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .signingIn: return .signingIn
        case .connected: return .connected
        case .disconnecting: return .disconnecting
        case .failed(let failure): return connectedDate == nil ? .failed(failure) : .dropped(failure)
        }
    }

    /// Connects a saved profile with its chosen endpoint; the saved sign-in is reused unless `signInAgain`.
    func connect(_ definition: ClientVPNProfileDefinition, secrets: ClientVPNProfileSecrets, signInAgain: Bool = false) async throws {
        let text = try await ClientVPNProfileStore.connectionText(for: definition, secrets: secrets)
        connect(profileID: definition.stableID, profileName: definition.name, profile: text, signInAgain: signInAgain)
    }
}

extension EnvironmentValues {
    @Entry var clientVPNSecrets = ClientVPNProfileSecrets(keychain: Keychain(accessGroup: KeychainAccessGroup.shared))
}

extension ClientVPNTunnelSettings {
    /// Whether every destination goes through the tunnel.
    var routesAllTraffic: Bool {
        routes.contains("0.0.0.0/0") || routes.contains("::/0")
    }

    /// The first assigned address without its prefix length, as people read an IP address.
    var address: String? {
        addresses.first.map { String($0.split(separator: "/").first ?? Substring($0)) }
    }
}
