import Foundation

extension Wire {
    /// RFC 8628 / AWS OIDC error envelope.
    ///
    /// Returned when a token request fails with 4xx.
    internal struct OAuthErrorResponse: Codable, Sendable {
        let error: String
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }
}
