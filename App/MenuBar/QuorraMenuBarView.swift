import AppKit
import ClientVPN
import DatabaseProxy
import IAMIdentityCenter
import QuorraAppLogic
import SwiftData
import SwiftUI

/// Shortens a menu item title to the 30 characters a menu bar menu can show comfortably.
func menuTitle(_ title: String) -> String {
    title.count <= 30 ? title : String(title.prefix(29)) + "…"
}

/// The menu bar menu. Each feature has a section; running items are listed at the top level
/// and the rest move into an "Other" submenu, so the menu stays short without hiding anything
/// active. Every item's actions live in its own submenu.
struct QuorraMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \IMDSEndpointDefinition.name) private var endpoints: [IMDSEndpointDefinition]
    @Query(sort: \SessionDefinition.name) private var sessions: [SessionDefinition]
    @Query(sort: \ClientVPNProfileDefinition.name) private var vpns: [ClientVPNProfileDefinition]
    @Query(sort: \DatabaseConnectionDefinition.name) private var databases: [DatabaseConnectionDefinition]
    let appUpdater: AppUpdater
    let presentationController: AppPresentationController
    let runtimeCoordinator: AppRuntimeCoordinator
    let imdsModel: IMDSModel
    let credentialsModel: CredentialsModel
    let databaseModel: DatabaseModel
    let clientVPNController: ClientVPNController
    let clientVPNSecrets: ClientVPNProfileSecrets
    let notificationCoordinator: DefaultIMDSNotificationCoordinator

    var body: some View {
        if let sessionName = runtimeCoordinator.defaultEndpointSignInSessionName {
            Button {
                runtimeCoordinator.signIn(to: sessionName)
            } label: {
                Label(menuTitle("Sign In to \(sessionName)…"), systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
            }

            Divider()
        }

        if !runtimeCoordinator.activeSignIns.isEmpty {
            Label("IAM Identity Center sign-in in progress", systemImage: "person.badge.clock")
                .disabled(true)

            ForEach(runtimeCoordinator.activeSignIns, id: \.sessionName) { progress in
                Button {
                    runtimeCoordinator.openAuthenticationPage(for: progress.sessionName)
                } label: {
                    Label("Open sign-in for \(progress.sessionName)", systemImage: "safari")
                }

                if let userCode = progress.userCode {
                    Text("Code \(userCode) · expires \(progress.expiresAt.formatted(date: .omitted, time: .shortened))")
                        .disabled(true)
                }
            }

            Divider()
        }

        Section("AWS") {
            ForEach(topLevelEndpoints, id: \.stableIDString) { definition in
                endpointMenu(definition)
            }

            if !otherEndpoints.isEmpty {
                Menu("Other Endpoints") {
                    ForEach(otherEndpoints, id: \.stableIDString) { definition in
                        endpointMenu(definition)
                    }
                }
                .badge(otherEndpoints.count)
            }

            ForEach(topLevelSessions, id: \.stableIDString) { session in
                sessionMenu(session)
            }

            if !otherSessions.isEmpty {
                Menu("Other Sessions") {
                    ForEach(otherSessions, id: \.stableIDString) { session in
                        sessionMenu(session)
                    }
                }
                .badge(otherSessions.count)
            }
        }

        if !vpns.isEmpty {
            Section("VPN") {
                ForEach(topLevelVPNs, id: \.stableIDString) { profile in
                    vpnMenu(profile)
                }

                if !otherVPNs.isEmpty {
                    Menu("Other VPNs") {
                        ForEach(otherVPNs, id: \.stableIDString) { profile in
                            vpnMenu(profile)
                        }
                    }
                    .badge(otherVPNs.count)
                }
            }
        }

        if !databases.isEmpty {
            Section("Databases") {
                ForEach(topLevelDatabases, id: \.stableIDString) { connection in
                    databaseMenu(connection)
                }

                if !otherDatabases.isEmpty {
                    Menu("Other Databases") {
                        ForEach(otherDatabases, id: \.stableIDString) { connection in
                            databaseMenu(connection)
                        }
                    }
                    .badge(otherDatabases.count)
                }
            }
        }

        Divider()

        Button("Open Quorra…") {
            presentMainWindow()
        }
        .keyboardShortcut("o")

        Button("Settings…") {
            presentationController.prepareForInteractivePresentation()
            openSettings()
            NSApplication.shared.activate()
        }
        .keyboardShortcut(",")

        Button("Check for Updates…") {
            appUpdater.checkForUpdates()
        }

        Divider()

        Button("Quit Quorra") {
            presentationController.terminate()
        }
        .keyboardShortcut("q")
    }

    private func endpointMenu(_ definition: IMDSEndpointDefinition) -> some View {
        EndpointMenu(
            definition: definition,
            state: imdsModel.state(forEndpointID: definition.stableIDString),
            profileChoices: runtimeCoordinator.endpointProfileChoices,
            runtimeCoordinator: runtimeCoordinator,
            showInQuorra: showInQuorra
        )
    }

    private func sessionMenu(_ session: SessionDefinition) -> some View {
        SessionMenu(
            sessionName: session.name,
            status: sessionStatus(session),
            runtimeCoordinator: runtimeCoordinator,
            credentialsModel: credentialsModel,
            showInQuorra: showInQuorra
        )
    }

    private func vpnMenu(_ profile: ClientVPNProfileDefinition) -> some View {
        ClientVPNMenu(
            profile: profile,
            controller: clientVPNController,
            secrets: clientVPNSecrets,
            otherName: connectedVPNName(otherThan: profile),
            showInQuorra: showInQuorra
        )
    }

    /// Favourite VPNs and any that are connecting, connected or failed are top-level; the rest go
    /// under Other VPNs.
    private var topLevelVPNs: [ClientVPNProfileDefinition] {
        vpns.filter(isTopLevel)
    }

    private var otherVPNs: [ClientVPNProfileDefinition] {
        vpns.filter { !isTopLevel($0) }
    }

    private func isTopLevel(_ profile: ClientVPNProfileDefinition) -> Bool {
        let status = clientVPNController.status(for: profile.stableID)
        return profile.isFavorite || status.isActive || status.failure != nil
    }

    /// The VPN holding the one tunnel macOS runs, when it isn't `profile`.
    private func connectedVPNName(otherThan profile: ClientVPNProfileDefinition) -> String? {
        guard clientVPNController.status(for: profile.stableID) == .blocked else { return nil }
        return vpns.first { $0.stableID == clientVPNController.profileID }?.name ?? "Another VPN"
    }

    private func databaseMenu(_ connection: DatabaseConnectionDefinition) -> some View {
        DatabaseMenu(connection: connection, databaseModel: databaseModel, showInQuorra: showInQuorra)
    }

    /// Favourite and running databases are top-level; the rest go under Other Databases.
    private var topLevelDatabases: [DatabaseConnectionDefinition] {
        databases.filter(isTopLevel)
    }

    private var otherDatabases: [DatabaseConnectionDefinition] {
        databases.filter { !isTopLevel($0) }
    }

    private func isTopLevel(_ connection: DatabaseConnectionDefinition) -> Bool {
        connection.isFavorite || databaseModel.status(for: connection.stableID).state.isRunning
    }

    /// The default endpoint always leads; other endpoints are top-level while they run,
    /// start, or need attention.
    private var topLevelEndpoints: [IMDSEndpointDefinition] {
        let defaults = endpoints.filter(DefaultIMDSEndpoint.matches)
        let running = endpoints.filter { !DefaultIMDSEndpoint.matches($0) && isRunning($0) }
        return defaults + running
    }

    private var otherEndpoints: [IMDSEndpointDefinition] {
        endpoints.filter { !DefaultIMDSEndpoint.matches($0) && !isRunning($0) }
    }

    private func isRunning(_ definition: IMDSEndpointDefinition) -> Bool {
        imdsModel.state(forEndpointID: definition.stableIDString) != .inactive
    }

    /// A session is top-level unless it is signed out.
    private var topLevelSessions: [SessionDefinition] {
        sessions.filter { sessionStatus($0) != .signedOut }
    }

    private var otherSessions: [SessionDefinition] {
        sessions.filter { sessionStatus($0) == .signedOut }
    }

    private func sessionStatus(_ session: SessionDefinition) -> SessionAuthStatus {
        credentialsModel.status[session.name] ?? .signedOut
    }

    private func showInQuorra(_ selection: DetailSelection) {
        notificationCoordinator.requestOpen(selection)
        presentMainWindow()
    }

    private func presentMainWindow() {
        presentationController.prepareForInteractivePresentation()
        openWindow(id: QuorraSceneID.mainWindow)
        NSApplication.shared.activate()
    }
}
