import Foundation

/// Maps HTTP errors and OAuth error envelopes to typed `IAMIdentityCenterError` cases.
internal enum HTTPErrorMapping {
    private static let decoder = JSONDecoder()

    static func mapOAuthError(_ data: Data) -> IAMIdentityCenterError {
        guard let envelope = try? decoder.decode(Wire.OAuthErrorResponse.self, from: data) else {
            return .malformedResponse("OAuth error response not decodable")
        }

        switch envelope.error {
        case "authorization_pending": return .authorizationPending
        case "slow_down":              return .slowDown
        case "access_denied":          return .accessDenied
        case "expired_token":          return .expiredDeviceCode
        case "invalid_grant":          return .invalidGrant
        case "invalid_client":         return .invalidClient
        default:
            return .awsError(code: envelope.error, description: envelope.errorDescription)
        }
    }

    static func mapHTTPError(response: URLResponse?, data: Data?) -> IAMIdentityCenterError? {
        guard let httpResponse = response as? HTTPURLResponse else {
            return .malformedResponse("Response is not HTTP")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let data, (400..<500).contains(httpResponse.statusCode) {
                return mapOAuthError(data)
            }
            let bodyString = data.flatMap { String(data: $0, encoding: .utf8) }
            return .httpStatus(httpResponse.statusCode, body: bodyString)
        }
        return nil
    }
}
