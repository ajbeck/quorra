import Testing
@testable import IAMIdentityCenter

/// Tests for the pure error-classification table.
///
/// No SDK imports — the mapper operates on `(typeName, message)` strings, so the test
/// surface is string-in / enum-out. That's the entire point of structuring
/// `SDKErrorMapping` as a pure function over a discriminator pair: SDK exception
/// construction is undocumented/private, but classification is exhaustively testable
/// in isolation.
@Suite struct SDKErrorMappingTests {

    // MARK: - OIDC table

    @Test func oidcInvalidClient() {
        #expect(SDKErrorMapping.mapOIDC(typeName: "InvalidClientException", message: nil) == .invalidClient)
    }

    @Test func oidcAuthorizationPending() {
        #expect(SDKErrorMapping.mapOIDC(typeName: "AuthorizationPendingException", message: nil) == .authorizationPending)
    }

    @Test func oidcSlowDown() {
        #expect(SDKErrorMapping.mapOIDC(typeName: "SlowDownException", message: nil) == .slowDown)
    }

    @Test func oidcAccessDenied() {
        #expect(SDKErrorMapping.mapOIDC(typeName: "AccessDeniedException", message: nil) == .accessDenied)
    }

    @Test func oidcExpiredToken() {
        #expect(SDKErrorMapping.mapOIDC(typeName: "ExpiredTokenException", message: nil) == .expiredDeviceCode)
    }

    @Test func oidcInvalidGrant() {
        #expect(SDKErrorMapping.mapOIDC(typeName: "InvalidGrantException", message: nil) == .invalidGrant)
    }

    @Test func oidcInvalidRequestCarriesMessage() {
        let mapped = SDKErrorMapping.mapOIDC(
            typeName: "InvalidRequestException",
            message: "Invalid start url provided"
        )
        guard case .awsError(let code, let desc) = mapped else {
            Issue.record("expected .awsError, got \(mapped)")
            return
        }
        #expect(code == "invalid_request")
        #expect(desc == "Invalid start url provided")
    }

    @Test func oidcUnauthorizedClient() {
        let mapped = SDKErrorMapping.mapOIDC(typeName: "UnauthorizedClientException", message: "client revoked")
        guard case .awsError(let code, let desc) = mapped else {
            Issue.record("expected .awsError, got \(mapped)")
            return
        }
        #expect(code == "unauthorized_client")
        #expect(desc == "client revoked")
    }

    @Test func oidcInternalServer() {
        let mapped = SDKErrorMapping.mapOIDC(typeName: "InternalServerException", message: "boom")
        guard case .awsError(let code, _) = mapped else {
            Issue.record("expected .awsError, got \(mapped)")
            return
        }
        #expect(code == "server_error")
    }

    @Test func oidcUnknownFallsThrough() {
        let mapped = SDKErrorMapping.mapOIDC(typeName: "FutureSDKException", message: "msg")
        guard case .awsError(let code, let desc) = mapped else {
            Issue.record("expected .awsError, got \(mapped)")
            return
        }
        #expect(code == "unknown")
        #expect(desc == "msg")
    }

    @Test func oidcUnknownFallsThroughEmptyMessage() {
        let mapped = SDKErrorMapping.mapOIDC(typeName: "FutureSDKException", message: nil)
        guard case .awsError(let code, let desc) = mapped else {
            Issue.record("expected .awsError, got \(mapped)")
            return
        }
        #expect(code == "unknown")
        #expect(desc == "FutureSDKException")
    }
}
