import Foundation
import Observation
import IAMIdentityCenter

/// Observable presenter for IAM Identity Center sign-in state.
///
/// Wraps the actor's `signIn` flow with UI-friendly state: an in-flight dictionary the view
/// reads to render progress, and a last-error dictionary the view reads to render failures.
/// All public mutations go through MainActor methods.
@Observable
@MainActor
final class CredentialsModel {
    private(set) var inFlight: [String: SignInProgress] = [:]
    private(set) var lastError: [String: IAMIdentityCenterError] = [:]

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
        lastError[sessionName] = nil

        do {
            _ = try await service.signIn(
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
            inFlight[sessionName] = nil
        } catch let error as IAMIdentityCenterError {
            inFlight[sessionName] = nil
            lastError[sessionName] = error
        } catch {
            inFlight[sessionName] = nil
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
    #endif
}
