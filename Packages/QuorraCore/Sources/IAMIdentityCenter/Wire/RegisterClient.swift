import Foundation

extension Wire {
    /// POST /client/register request body.
    internal struct RegisterClientRequest: Codable, Sendable {
        let clientName: String
        let clientType: String
        let scopes: [String]?
    }

    /// POST /client/register response body.
    internal struct RegisterClientResponse: Codable, Sendable {
        let clientId: String
        let clientSecret: String
        let clientIdIssuedAt: Int
        let clientSecretExpiresAt: Int
    }
}
