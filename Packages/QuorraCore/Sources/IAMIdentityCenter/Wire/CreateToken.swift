import Foundation

extension Wire {
    /// POST /token request body (device-code grant only).
    internal struct CreateTokenRequest: Codable, Sendable {
        let clientId: String
        let clientSecret: String
        let deviceCode: String
        let grantType: String
    }

    /// POST /token response body.
    internal struct CreateTokenResponse: Codable, Sendable {
        let accessToken: String
        let tokenType: String
        let expiresIn: Int
        let refreshToken: String?
        let idToken: String?
    }
}
