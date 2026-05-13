import Foundation

extension IdentityCenterService {
    /// Polls CreateToken until the user completes the browser flow or the device code expires.
    ///
    /// Implements RFC 8628 §3.5 polling rules:
    /// - Sleep `interval` BEFORE the first poll (not after)
    /// - On `authorization_pending`: keep the same interval, sleep, retry
    /// - On `slow_down`: add 5s to the interval (permanent increase), sleep, retry
    /// - On terminal errors (`expired_token`, `access_denied`, etc.): stop immediately
    /// - Wall-clock timeout: when `Date() > verification.expiresAt`, throw `.deviceFlowTimedOut`
    internal func pollForToken(
        client: StoredOIDCClient,
        deviceCode: String,
        sessionName: String,
        verification: DeviceVerification
    ) async throws -> StoredSSOToken {
        var interval = verification.interval

        while await sleeper.now < verification.expiresAt {
            try await sleeper.sleep(for: interval)
            try Task.checkCancellation()

            do {
                let token = try await oidcClient.createToken(
                    client: client,
                    deviceCode: deviceCode,
                    sessionName: sessionName
                )
                return token
            } catch IAMIdentityCenterError.authorizationPending {
                // User hasn't completed the browser step yet — keep polling at current interval
                continue
            } catch IAMIdentityCenterError.slowDown {
                // Server requests slower polling — add 5s and continue
                interval += 5
                continue
            } catch let error as IAMIdentityCenterError {
                switch error {
                case .expiredDeviceCode, .accessDenied, .invalidGrant, .invalidClient:
                    // Terminal errors — stop polling immediately
                    throw error
                default:
                    // Other errors (network, malformed response, etc.) also stop polling
                    throw error
                }
            }
        }

        // Wall-clock deadline exceeded
        throw IAMIdentityCenterError.deviceFlowTimedOut
    }
}
