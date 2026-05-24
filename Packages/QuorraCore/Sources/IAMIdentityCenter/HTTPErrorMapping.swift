import Foundation

/// Maps Portal HTTP errors and AWS REST-JSON error envelopes to typed `IAMIdentityCenterError` cases.
internal enum HTTPErrorMapping {
    private static let decoder = JSONDecoder()

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
