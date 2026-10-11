import Testing
import AWSSSOOIDC
@testable import IAMIdentityCenter

@Suite struct SDKErrorMappingTests {
    @Test func knownOIDCErrorsMapToDomainErrors() {
        let cases: [(String, String?, IAMIdentityCenterError)] = [
            ("InvalidClientException", nil, .invalidClient),
            ("AuthorizationPendingException", nil, .authorizationPending),
            ("SlowDownException", nil, .slowDown),
            ("AccessDeniedException", nil, .accessDenied),
            ("ExpiredTokenException", nil, .expiredDeviceCode),
            ("InvalidGrantException", nil, .invalidGrant),
            ("InvalidRequestException", "Invalid start url provided", .awsError(code: "invalid_request", description: "Invalid start url provided")),
            ("UnauthorizedClientException", "client revoked", .awsError(code: "unauthorized_client", description: "client revoked")),
            ("InternalServerException", "boom", .awsError(code: "server_error", description: "boom")),
            ("InvalidScopeException", "bad scope", .awsError(code: "invalid_scope", description: "bad scope")),
            ("UnsupportedGrantTypeException", "unsupported", .awsError(code: "unsupported_grant_type", description: "unsupported")),
        ]

        for (typeName, message, expected) in cases {
            #expect(SDKErrorMapping.mapOIDC(typeName: typeName, message: message) == expected)
        }
    }

    @Test func refreshFailuresThatEndTheSessionAreTerminal() {
        // During a refresh the only token is the refresh token, so an expired token means the
        // Identity Center session has ended and the user has to sign in again.
        #expect(SDKErrorMapping.mapRefresh(.invalidGrant) == .refreshTokenRejected)
        #expect(SDKErrorMapping.mapRefresh(.expiredDeviceCode) == .refreshTokenRejected)
        #expect(SDKErrorMapping.mapRefresh(.invalidClient) == .refreshClientInvalid)
        #expect(SDKErrorMapping.mapRefresh(.slowDown) == .slowDown)
        #expect(SDKErrorMapping.mapRefresh(.awsError(code: "server_error", description: "boom")) == .awsError(code: "server_error", description: "boom"))
    }

    @Test func unknownOIDCErrorsPreserveDiagnostics() {
        #expect(
            SDKErrorMapping.mapOIDC(typeName: "FutureSDKException", message: "msg")
            == .awsError(code: "unknown", description: "msg")
        )
        #expect(
            SDKErrorMapping.mapOIDC(typeName: "FutureSDKException", message: nil)
            == .awsError(code: "unknown", description: "FutureSDKException")
        )
    }

    @Test func extractPreservesSDKServiceErrorMessage() {
        var error = InvalidRequestException()
        error.message = "Invalid start url provided"

        let extracted = SDKErrorMapping.extract(from: error)

        #expect(extracted.typeName == "InvalidRequestException")
        #expect(extracted.message == "Invalid start url provided")
    }
}
