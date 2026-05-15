import Foundation

/// Maps HTTP errors and AWS/OAuth error envelopes to typed `IAMIdentityCenterError` cases.
internal enum HTTPErrorMapping {
    private static let decoder = JSONDecoder()

    // MARK: - OIDC endpoints (OAuth error format)

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

    // MARK: - Portal endpoints (AWS REST-JSON 1.1 error format)

    /// Maps Portal API HTTP errors using the AWS REST-JSON 1.1 error envelope.
    ///
    /// The Portal uses `{ "__type": "ExceptionClass", "message": "..." }` for 4xx errors,
    /// not the OAuth `error`/`error_description` format used by the OIDC endpoints.
    ///
    /// D26 error mapping:
    /// - `ForbiddenException` → `.roleNotAssigned` (terminal — purge cached row)
    /// - `ResourceNotFoundException` → `.accountNotFound` (terminal — purge cached row)
    /// - 5xx → `.httpStatus` (transient — no Keychain mutation)
    /// - Network → `.network` (transient; handled upstream in `PortalClient.get`)
    static func mapPortalHTTPError(response: URLResponse?, data: Data?) -> IAMIdentityCenterError? {
        guard let httpResponse = response as? HTTPURLResponse else {
            return .malformedResponse("Portal response is not HTTP")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let data, (400..<500).contains(httpResponse.statusCode) {
                return mapPortalServiceError(data)
            }
            let bodyString = data.flatMap { String(data: $0, encoding: .utf8) }
            return .httpStatus(httpResponse.statusCode, body: bodyString)
        }
        return nil
    }

    private static func mapPortalServiceError(_ data: Data) -> IAMIdentityCenterError {
        guard let envelope = try? decoder.decode(Wire.AWSServiceErrorResponse.self, from: data) else {
            return .malformedResponse("Portal error response not decodable")
        }

        switch envelope.type {
        case "ForbiddenException":        return .roleNotAssigned
        case "ResourceNotFoundException": return .accountNotFound
        default:
            return .awsError(code: envelope.type, description: envelope.message)
        }
    }
}
