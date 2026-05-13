import Foundation
import IAMIdentityCenter

/// UI-shaped snapshot of an in-flight sign-in for a session.
///
/// Mirrors `DeviceVerification` plus the moment the sign-in started. The view layer reads this to
/// render the inline sign-in panel; the model populates it from the `verificationHandler` callback
/// and removes it on completion or cancellation.
struct SignInProgress: Sendable, Hashable {
    let sessionName: String
    let userCode: String
    let verificationUri: URL
    let verificationUriComplete: URL
    let expiresAt: Date
    let startedAt: Date

    init(sessionName: String, verification: DeviceVerification, startedAt: Date = Date()) {
        self.sessionName = sessionName
        self.userCode = verification.userCode
        self.verificationUri = verification.verificationUri
        self.verificationUriComplete = verification.verificationUriComplete
        self.expiresAt = verification.expiresAt
        self.startedAt = startedAt
    }
}
