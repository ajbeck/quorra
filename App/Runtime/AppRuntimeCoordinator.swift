import AWSConfigINI
import Foundation
import IAMIdentityCenter
import Observation
import QuorraAppLogic
import QuorraProfiles
import SwiftData
import os

private let runtimeLogger = Logger(subsystem: "dev.ajbeck.quorra", category: "Runtime")

struct DefaultEndpointAuthenticationNotice: Equatable, Identifiable {
    let endpointID: String
    let profileName: String
    let sessionName: String

    var id: String { endpointID }
}

enum AppRuntimeOperationError: LocalizedError {
    case profilesNotReady
    case profileNotFound(String)
    case endpointNotConfigured(String)
    case authenticationRequired(profileName: String, sessionName: String)
    case endpointFailed(String)
    case profileSwitchUnavailable
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .profilesNotReady:
            return "Quorra is still loading profiles. Try again in a moment."
        case .profileNotFound(let name):
            return "The profile ‘\(name)’ is unavailable or is missing its SSO configuration."
        case .endpointNotConfigured(let name):
            return "The endpoint ‘\(name)’ does not have a profile to serve."
        case .authenticationRequired(let profileName, let sessionName):
            return "Profile ‘\(profileName)’ requires sign-in to session ‘\(sessionName)’. Run `quorra profiles sign-in \(profileName)`, then try again."
        case .endpointFailed(let message):
            return message
        case .profileSwitchUnavailable:
            return "Only the Default IMDS Endpoint can switch profiles."
        case .persistenceFailed(let message):
            return "Quorra could not remember the endpoint change. \(message)"
        }
    }
}

/// Owns work that must continue when Quorra has no open main window.
///
/// The coordinator observes the app-scoped models directly instead of relying on
/// SwiftUI view tasks. This keeps profile loading, credential recovery, and the
/// persistent Default IMDS Endpoint tied to the process lifecycle.
@MainActor
@Observable
final class AppRuntimeCoordinator {
    private(set) var authenticationNotice: DefaultEndpointAuthenticationNotice?
    private(set) var defaultEndpointProfileName: String?

    var isDefaultEndpointEnabled: Bool {
        imdsModel.shouldRestoreDefaultEndpoint
    }

    var activeSignIns: [SignInProgress] {
        credentialsModel.inFlight.values.sorted {
            $0.sessionName.localizedStandardCompare($1.sessionName) == .orderedAscending
        }
    }

    @ObservationIgnored private let appModel: AppModel
    @ObservationIgnored private let profilesModel: ProfilesModel
    @ObservationIgnored private let credentialsModel: CredentialsModel
    @ObservationIgnored private let imdsModel: IMDSModel
    @ObservationIgnored private let imdsProxyController: IMDSProxyController
    @ObservationIgnored private let notificationCoordinator: DefaultIMDSNotificationCoordinator
    @ObservationIgnored private let authenticationBrowser: AuthenticationBrowser
    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let identityImportStorage: IdentityImportStorage

    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var isReconciling = false
    @ObservationIgnored private var needsReconciliation = false
    @ObservationIgnored private var needsForcedReconciliation = false
    @ObservationIgnored private var isRestoringDefaultEndpoint = false
    @ObservationIgnored private var loadedFolderURL: URL?
    @ObservationIgnored private var previousEligibleProfileNames: [String] = []
    @ObservationIgnored private var previousProfileStatus: [String: ProfileAuthStatus] = [:]
    @ObservationIgnored private var previousSignIns: [String: SignInProgress] = [:]
    @ObservationIgnored private var storeSaveObserver: (any NSObjectProtocol)?

    init(
        appModel: AppModel,
        profilesModel: ProfilesModel,
        credentialsModel: CredentialsModel,
        imdsModel: IMDSModel,
        imdsProxyController: IMDSProxyController,
        notificationCoordinator: DefaultIMDSNotificationCoordinator,
        authenticationBrowser: AuthenticationBrowser,
        modelContext: ModelContext,
        identityImportStorage: IdentityImportStorage = .default
    ) {
        self.appModel = appModel
        self.profilesModel = profilesModel
        self.credentialsModel = credentialsModel
        self.imdsModel = imdsModel
        self.imdsProxyController = imdsProxyController
        self.notificationCoordinator = notificationCoordinator
        self.authenticationBrowser = authenticationBrowser
        self.modelContext = modelContext
        self.identityImportStorage = identityImportStorage
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        previousSignIns = credentialsModel.inFlight
        installObservation()
        storeSaveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: modelContext,
            queue: .main
        ) { [weak self] notification in
            guard Self.saveAffectsRuntime(notification) else { return }
            Task { @MainActor [weak self] in
                await self?.requestReconciliation()
            }
        }

        await appModel.resolveStoredBookmark()
        await requestReconciliation(force: true)
    }

    func dismissAuthenticationNotice() {
        authenticationNotice = nil
    }

    func openAuthenticationPage(for sessionName: String) {
        guard let progress = credentialsModel.inFlight[sessionName] else { return }
        authenticationBrowser.open(progress.verificationUriComplete)
    }

    func setDefaultEndpointEnabled(_ isEnabled: Bool) async {
        imdsModel.rememberDefaultEndpointShouldRun(isEnabled)
        if isEnabled {
            await notificationCoordinator.requestAuthorizationIfNeeded()
            await requestReconciliation(force: true)
        } else {
            await stopDefaultEndpoint()
            authenticationNotice = nil
            notificationCoordinator.clearAuthenticationRequiredNotification()
        }
    }

    func repairDefaultEndpoint() async {
        let endpointID = DefaultIMDSEndpoint.stableIDString
        let shouldResume = imdsModel.shouldRestoreDefaultEndpoint
        await stopDefaultEndpoint()

        do {
            try await imdsProxyController.repairConfiguration()
            if shouldResume {
                await requestReconciliation(force: true)
            }
        } catch {
            imdsModel.setState(
                .failed(port: DefaultIMDSEndpoint.port, message: error.localizedDescription),
                forEndpointID: endpointID
            )
        }
    }

    func signIn(to sessionName: String) {
        guard let session = try? IdentityStore.session(named: sessionName, in: modelContext),
              let startURL = URL(string: session.startURL) else { return }

        let region = session.region
        let scopes = session.registrationScopes
        Task {
            await credentialsModel.signIn(
                sessionName: sessionName,
                startUrl: startURL,
                region: region,
                scopes: scopes
            )
        }
    }

    func startEndpoint(_ definition: IMDSEndpointDefinition) async throws {
        guard case .loaded = profilesModel.loadState else {
            throw AppRuntimeOperationError.profilesNotReady
        }
        guard !definition.profileName.isEmpty else {
            throw AppRuntimeOperationError.endpointNotConfigured(definition.name)
        }
        guard let node = eligibleDefaultEndpointProfiles.first(where: { $0.name == definition.profileName }) else {
            throw AppRuntimeOperationError.profileNotFound(definition.profileName)
        }

        if DefaultIMDSEndpoint.matches(definition) {
            await setDefaultEndpointEnabled(true)
        } else {
            await imdsModel.startEndpoint(
                endpointID: definition.stableIDString,
                for: node,
                credentialsModel: credentialsModel,
                bindAddress: definition.bindAddress,
                port: definition.port,
                allowsIMDSv1: definition.allowsIMDSv1,
                logContext: modelContext
            )
        }
        await observeCredentialStatus(for: node)
        try throwIfEndpointFailed(definition)
    }

    func stopEndpoint(_ definition: IMDSEndpointDefinition) async {
        if DefaultIMDSEndpoint.matches(definition) {
            await setDefaultEndpointEnabled(false)
        } else {
            imdsModel.stopEndpoint(forEndpointID: definition.stableIDString)
        }
    }

    func switchDefaultEndpointProfile(to profileName: String) async throws {
        guard case .loaded = profilesModel.loadState else {
            throw AppRuntimeOperationError.profilesNotReady
        }
        guard let targetNode = eligibleDefaultEndpointProfiles.first(where: { $0.name == profileName }) else {
            throw AppRuntimeOperationError.profileNotFound(profileName)
        }
        let definitions = try modelContext.fetch(FetchDescriptor<IMDSEndpointDefinition>())
        guard let definition = definitions.first(where: DefaultIMDSEndpoint.matches) else {
            throw AppRuntimeOperationError.profileSwitchUnavailable
        }
        guard definition.profileName != profileName else { return }

        let state = imdsModel.state(forEndpointID: definition.stableIDString)
        let previousProfileName = definition.profileName
        let previousProfile = definition.profile
        let switchedLive: Bool
        do {
            switchedLive = state.isActive
                ? try await imdsModel.switchEndpointProfile(
                    endpointID: definition.stableIDString,
                    to: targetNode,
                    credentialsModel: credentialsModel
                )
                : false
        } catch {
            throw AppRuntimeOperationError.endpointFailed(
                "The endpoint is still serving ‘\(previousProfileName)’. \(error.localizedDescription)"
            )
        }
        guard !state.isActive || switchedLive else {
            throw AppRuntimeOperationError.endpointFailed(
                "Quorra could not switch the running Default IMDS Endpoint."
            )
        }

        definition.profileName = profileName
        definition.profile = targetNode
        definition.updatedAt = .now
        do {
            try modelContext.save()
            defaultEndpointProfileName = profileName
        } catch {
            if !switchedLive {
                definition.profileName = previousProfileName
                definition.profile = previousProfile
            }
            throw AppRuntimeOperationError.persistenceFailed(error.localizedDescription)
        }

        if !switchedLive, imdsModel.shouldRestoreDefaultEndpoint {
            await requestReconciliation(force: true)
            try throwIfEndpointFailed(definition)
        }
    }

    private func throwIfEndpointFailed(_ definition: IMDSEndpointDefinition) throws {
        let state = imdsModel.state(forEndpointID: definition.stableIDString)
        if let failureMessage = state.failureMessage {
            if let node = try? IdentityStore.profile(named: definition.profileName, in: modelContext),
               let authenticationError = authenticationRequiredError(for: node) {
                throw authenticationError
            }
            throw AppRuntimeOperationError.endpointFailed(failureMessage)
        }
        guard state.isActive else {
            throw AppRuntimeOperationError.endpointFailed(
                "Quorra could not start ‘\(definition.name)’ with the selected profile."
            )
        }
    }

    private func observeCredentialStatus(for node: ProfileDefinition) async {
        guard let coordinates = credentialCoordinates(for: node) else { return }
        await credentialsModel.observeProfileStatus(
            forSession: coordinates.session,
            accountId: coordinates.account,
            roleName: coordinates.role
        )
    }

    private func authenticationRequiredError(for node: ProfileDefinition) -> AppRuntimeOperationError? {
        switch credentialStatus(for: node) {
        case .notSignedIn(let sessionName), .signInExpired(let sessionName):
            return .authenticationRequired(profileName: node.name, sessionName: sessionName)
        case .ready, .none:
            return nil
        }
    }

    /// Sessions, profiles, and endpoint definitions live in the store, so a save that touches them
    /// re-runs reconciliation; log batches and other saves do not.
    private nonisolated static func saveAffectsRuntime(_ notification: Notification) -> Bool {
        let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        let entityNames: Set<String> = ["SessionDefinition", "ProfileDefinition", "IMDSEndpointDefinition"]
        return keys.contains { key in
            guard let identifiers = notification.userInfo?[key] as? [PersistentIdentifier] else { return false }
            return identifiers.contains { entityNames.contains($0.entityName) }
        }
    }

    private func installObservation() {
        withObservationTracking {
            _ = appModel.phase
            _ = profilesModel.loadState
            _ = profilesModel.groups
            _ = credentialsModel.profileStatus
            _ = credentialsModel.inFlight
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.installObservation()
                await self.requestReconciliation()
            }
        }
    }

    private func requestReconciliation(force: Bool = false) async {
        needsReconciliation = true
        if force {
            needsForcedReconciliation = true
        }
        guard !isReconciling else { return }

        isReconciling = true
        defer { isReconciling = false }
        while needsReconciliation {
            needsReconciliation = false
            let isForced = needsForcedReconciliation
            needsForcedReconciliation = false
            await reconcileObservedState(force: isForced)
        }
    }

    private func importIdentityStoreIfNeeded() {
        guard !identityImportStorage.hasCompleted else { return }
        do {
            let summary = try IdentityStoreImporter.importSSOProfiles(from: profilesModel.groups, into: modelContext)
            identityImportStorage.markCompleted()
            runtimeLogger.info("Imported \(summary.sessions) sessions and \(summary.profiles) profiles into the identity store; linked \(summary.linkedEndpoints) endpoints; left \(summary.skippedProfiles.count) profiles in the file.")
        } catch {
            runtimeLogger.error("Identity store import failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func reconcileObservedState(force: Bool) async {
        handleSignInPresentationChange()

        guard case .ready(let folderURL) = appModel.phase else {
            loadedFolderURL = nil
            previousEligibleProfileNames = []
            previousProfileStatus = [:]
            return
        }

        let folderChanged = loadedFolderURL != folderURL
        if folderChanged {
            loadedFolderURL = folderURL
            await profilesModel.load(folder: folderURL)
        }

        guard case .loaded = profilesModel.loadState else { return }
        if folderChanged {
            importIdentityStoreIfNeeded()
        }
        let eligibleProfileNames = eligibleDefaultEndpointProfiles.map(\.name)
        let profilesChanged = eligibleProfileNames != previousEligibleProfileNames
        let credentialStatusChanged = credentialsModel.profileStatus != previousProfileStatus

        guard force || folderChanged || profilesChanged || credentialStatusChanged else { return }

        previousEligibleProfileNames = eligibleProfileNames
        previousProfileStatus = credentialsModel.profileStatus
        if force || folderChanged || profilesChanged {
            await credentialsModel.initializeStatuses(
                forSessions: ((try? IdentityStore.sessions(in: modelContext)) ?? []).map(\.name)
            )
            previousProfileStatus = credentialsModel.profileStatus
        }
        await reconcileDefaultEndpoint()
    }

    private func handleSignInPresentationChange() {
        let currentSignIns = credentialsModel.inFlight
        defer { previousSignIns = currentSignIns }

        for (sessionName, progress) in currentSignIns where previousSignIns[sessionName] == nil {
            authenticationBrowser.open(progress.verificationUriComplete)
            return
        }
    }

    private var eligibleDefaultEndpointProfiles: [ProfileDefinition] {
        (try? IdentityStore.eligibleProfiles(in: modelContext)) ?? []
    }

    private func reconcileDefaultEndpoint() async {
        guard let definition = try? DefaultIMDSEndpoint.ensureDefinition(
            in: modelContext,
            availableProfiles: eligibleDefaultEndpointProfiles
        ) else { return }
        defaultEndpointProfileName = definition.profileName.isEmpty ? nil : definition.profileName

        guard imdsModel.shouldRestoreDefaultEndpoint else {
            await stopDefaultEndpoint()
            authenticationNotice = nil
            notificationCoordinator.clearAuthenticationRequiredNotification()
            return
        }

        let endpointID = definition.stableIDString
        guard let node = definition.profile ?? (try? IdentityStore.profile(named: definition.profileName, in: modelContext)) else {
            imdsModel.stopEndpoint(forEndpointID: endpointID)
            return
        }

        let state = imdsModel.state(forEndpointID: endpointID)
        let runtime = imdsModel.runtimeInfo(forEndpointID: endpointID)
        if state.isActive, runtime?.servedProfileName != definition.profileName {
            do {
                try await imdsModel.switchEndpointProfile(
                    endpointID: endpointID,
                    to: node,
                    credentialsModel: credentialsModel
                )
                authenticationNotice = nil
                notificationCoordinator.clearAuthenticationRequiredNotification()
                return
            } catch {
                imdsModel.stopEndpoint(forEndpointID: endpointID)
            }
        } else if state.isActive {
            authenticationNotice = nil
            notificationCoordinator.clearAuthenticationRequiredNotification()
            return
        }

        await restoreDefaultEndpointIfNeeded(definition, node: node)
    }

    private func restoreDefaultEndpointIfNeeded(
        _ definition: IMDSEndpointDefinition,
        node: ProfileDefinition
    ) async {
        guard !isRestoringDefaultEndpoint else { return }
        let state = imdsModel.state(forEndpointID: definition.stableIDString)
        guard !state.isActive, !state.isStarting else { return }

        isRestoringDefaultEndpoint = true
        defer { isRestoringDefaultEndpoint = false }
        await imdsModel.startEndpoint(
            endpointID: definition.stableIDString,
            for: node,
            credentialsModel: credentialsModel,
            bindAddress: DefaultIMDSEndpoint.backendBindAddress,
            port: DefaultIMDSEndpoint.backendPort,
            allowsIMDSv1: definition.allowsIMDSv1,
            logContext: modelContext
        )

        guard imdsModel.state(forEndpointID: definition.stableIDString).isActive else {
            await presentAuthenticationNoticeIfNeeded(
                for: node,
                endpointID: definition.stableIDString
            )
            return
        }

        do {
            try await imdsProxyController.start()
            authenticationNotice = nil
            notificationCoordinator.clearAuthenticationRequiredNotification()
        } catch {
            imdsModel.stopEndpoint(forEndpointID: definition.stableIDString)
            imdsModel.setState(
                .failed(port: definition.port, message: error.localizedDescription),
                forEndpointID: definition.stableIDString
            )
        }
    }

    private func stopDefaultEndpoint() async {
        let endpointID = DefaultIMDSEndpoint.stableIDString
        imdsProxyController.stop()
        imdsModel.stopEndpoint(forEndpointID: endpointID)
        await imdsProxyController.setInstalled(false)
    }

    private func presentAuthenticationNoticeIfNeeded(
        for node: ProfileDefinition,
        endpointID: String
    ) async {
        guard let coordinates = credentialCoordinates(for: node) else { return }
        await credentialsModel.observeProfileStatus(
            forSession: coordinates.session,
            accountId: coordinates.account,
            roleName: coordinates.role
        )
        guard !credentialStatus(for: node).isReady else { return }

        switch credentialsModel.profileStatus[coordinates.key] {
        case .notSignedIn(let sessionName), .signInExpired(let sessionName):
            let notice = DefaultEndpointAuthenticationNotice(
                endpointID: endpointID,
                profileName: node.name,
                sessionName: sessionName
            )
            let shouldNotify = authenticationNotice != notice
            authenticationNotice = notice
            if shouldNotify {
                await notificationCoordinator.notifyAuthenticationRequired(profileName: node.name)
            }
        case .ready, .none:
            break
        }
    }

    private func credentialCoordinates(
        for node: ProfileDefinition
    ) -> (session: String, account: String, role: String, key: String)? {
        guard let coordinates = node.credentialCoordinates else { return nil }
        return (coordinates.session, coordinates.account, coordinates.role, coordinates.key)
    }

    private func credentialStatus(for node: ProfileDefinition) -> ProfileAuthStatus? {
        guard let coordinates = credentialCoordinates(for: node) else { return nil }
        return credentialsModel.profileStatus[coordinates.key]
    }
}

#if DEBUG
extension AppRuntimeCoordinator {
    static func preview() -> AppRuntimeCoordinator {
        let container = try! QuorraMetadataSchema.makeContainer(inMemory: true)
        let appModel = AppModel(initialPhase: .setup)
        let profilesModel = ProfilesModel()
        let credentialsModel = CredentialsModel(service: PreviewIdentityCenterService())
        let imdsModel = IMDSModel()
        let notificationCoordinator = DefaultIMDSNotificationCoordinator()
        return AppRuntimeCoordinator(
            appModel: appModel,
            profilesModel: profilesModel,
            credentialsModel: credentialsModel,
            imdsModel: imdsModel,
            imdsProxyController: IMDSProxyController(),
            notificationCoordinator: notificationCoordinator,
            authenticationBrowser: AuthenticationBrowser(),
            modelContext: container.mainContext
        )
    }
}
#endif

private extension Optional where Wrapped == ProfileAuthStatus {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}
