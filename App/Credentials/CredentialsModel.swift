import Foundation
import Observation
import IAMIdentityCenter

/// Observable presenter for IAM Identity Center sign-in state.
///
/// Wraps the actor's `signIn` flow with UI-friendly state: an in-flight dictionary the view
/// reads to render progress, a last-error dictionary the view reads to render failures, and a
/// last-token dictionary the view reads to render the post-sign-in success state.
/// All public mutations go through MainActor methods.
@Observable
@MainActor
final class CredentialsModel {
    private(set) var inFlight: [String: SignInProgress] = [:]
    private(set) var lastError: [String: IAMIdentityCenterError] = [:]
    private(set) var lastToken: [String: StoredSSOToken] = [:]

    @ObservationIgnored private let service: any IdentityCenterServicing

    init(service: any IdentityCenterServicing) {
        self.service = service
    }

    /// Drives sign-in for the given SSO session.
    ///
    /// On the verificationHandler callback, populates `inFlight[sessionName]` and opens the system
    /// browser via `NSWorkspace`. On success, removes the in-flight entry and clears any prior error.
    /// On failure, removes the in-flight entry and stores the error in `lastError[sessionName]`.
    func signIn(
        sessionName: String,
        startUrl: URL,
        region: String,
        scopes: [String]
    ) async {
        // Guard against assigning nil onto an already-absent key — `Dictionary` subscript-set
        // still triggers `@Observable` invalidation regardless of whether the value changed.
        if lastError[sessionName] != nil { lastError[sessionName] = nil }
        if lastToken[sessionName] != nil { lastToken[sessionName] = nil }

        do {
            let token = try await service.signIn(
                sessionName: sessionName,
                startUrl: startUrl,
                region: region,
                scopes: scopes,
                clientName: "Quorra",
                verificationHandler: { [weak self] verification in
                    guard let self else { return }
                    await self.recordVerification(sessionName: sessionName, verification: verification)
                }
            )
            lastToken[sessionName] = token
            if inFlight[sessionName] != nil { inFlight[sessionName] = nil }
        } catch let error as IAMIdentityCenterError {
            if inFlight[sessionName] != nil { inFlight[sessionName] = nil }
            lastError[sessionName] = error
        } catch {
            if inFlight[sessionName] != nil { inFlight[sessionName] = nil }
            lastError[sessionName] = .malformedResponse(String(reflecting: error))
        }
    }

    /// Cancels an in-flight sign-in. The corresponding `signIn(...)` call will throw `.userCancelled`.
    func cancelSignIn(sessionName: String) async {
        await service.cancelSignIn(sessionName: sessionName)
    }

    /// Verification-handler callback. MainActor-isolated mutation hop required because the actor's
    /// callback runs in the actor's isolation, not the MainActor's.
    private func recordVerification(sessionName: String, verification: DeviceVerification) {
        let progress = SignInProgress(sessionName: sessionName, verification: verification)
        inFlight[sessionName] = progress
    }

    #if DEBUG
    /// Test seam: write-access to `lastError` for setting up "prior failure" preconditions.
    /// Not callable from production code paths.
    func seedLastErrorForTesting(_ error: IAMIdentityCenterError, sessionName: String) {
        lastError[sessionName] = error
    }

    /// Test seam: write-access to `inFlight` for setting up "signing in" preconditions.
    /// Not callable from production code paths.
    func seedInFlightForTesting(_ progress: SignInProgress, sessionName: String) {
        inFlight[sessionName] = progress
    }

    /// Test seam: write-access to `lastToken` for setting up "signed in" preconditions.
    /// Not callable from production code paths.
    func seedLastTokenForTesting(_ token: StoredSSOToken, sessionName: String) {
        lastToken[sessionName] = token
    }
    #endif
}
