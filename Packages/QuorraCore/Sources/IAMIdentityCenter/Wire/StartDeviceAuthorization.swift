import Foundation

extension Wire {
    /// POST /device_authorization request body.
    internal struct StartDeviceAuthorizationRequest: Codable, Sendable {
        let clientId: String
        let clientSecret: String
        let startUrl: String
    }

    /// POST /device_authorization response body.
    internal struct StartDeviceAuthorizationResponse: Codable, Sendable {
        let deviceCode: String
        let userCode: String
        let verificationUri: String
        let verificationUriComplete: String
        let expiresIn: Int
        let interval: Int?
    }
}
