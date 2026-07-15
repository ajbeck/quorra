import Foundation
import IAMIdentityCenter

/// UI-shaped snapshot of an in-flight sign-in for a session.
///
/// Mirrors `DeviceVerification` plus the moment the sign-in started. The view layer reads this to
/// render the inline sign-in panel; the model populates it from the `verificationHandler` callback
/// and removes it on completion or cancellation.
public struct SignInProgress: Sendable, Hashable {
    public let sessionName: String
    public let userCode: String
    public let verificationUri: URL
    public let verificationUriComplete: URL
    public let expiresAt: Date
    public let startedAt: Date

    public init(sessionName: String, verification: DeviceVerification, startedAt: Date = Date()) {
        self.sessionName = sessionName
        self.userCode = verification.userCode
        self.verificationUri = verification.verificationUri
        self.verificationUriComplete = verification.verificationUriComplete
        self.expiresAt = verification.expiresAt
        self.startedAt = startedAt
    }
}
