import AppKit
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
    let appUpdater: AppUpdater
    let presentationController: AppPresentationController
    let runtimeCoordinator: AppRuntimeCoordinator
    let imdsModel: IMDSModel
    let credentialsModel: CredentialsModel
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

                Text("Code \(progress.userCode) · expires \(progress.expiresAt.formatted(date: .omitted, time: .shortened))")
                    .disabled(true)
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
