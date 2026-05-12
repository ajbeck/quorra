import Foundation

/// Payload passed to the `verificationHandler` callback during `signIn`.
///
/// Contains everything the app needs to open the browser and show the user code.
public struct DeviceVerification: Sendable, Hashable {
    /// User code to display as a fallback.
    public let userCode: String

    /// Verification URL (without the user code embedded).
    public let verificationUri: URL

    /// Verification URL with the user code pre-filled as a query parameter.
    public let verificationUriComplete: URL

    /// When the device code expires.
    public let expiresAt: Date

    /// Minimum polling interval in seconds.
    public let interval: TimeInterval

    public init(
        userCode: String,
        verificationUri: URL,
        verificationUriComplete: URL,
        expiresAt: Date,
        interval: TimeInterval
    ) {
        self.userCode = userCode
        self.verificationUri = verificationUri
        self.verificationUriComplete = verificationUriComplete
        self.expiresAt = expiresAt
        self.interval = interval
    }
}
