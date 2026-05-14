import Foundation
@testable import IAMIdentityCenter

/// Actor-based test double for `OIDCRequesting`.
///
/// Replaces `StubURLProtocol` for tests that exercise actor behavior (refresh outcome, sign-out
/// sequencing, session lock) rather than wire encoding. Wire-layer tests (`OIDCClientTests`,
/// `OIDCClientRefreshTests`) keep using `StubURLProtocol` since they specifically test HTTP
/// encoding and error mapping.
///
/// Usage:
/// ```swift
/// let stub = StubOIDCRequesting()
/// await stub.setNextRefreshResult(.success(newToken))
/// let service = IdentityCenterService(keychain: keychain, oidcClient: stub)
/// ```
actor StubOIDCRequesting: OIDCRequesting {

    // MARK: - Canned results (set per-test)

    var nextRegisterResult: Result<StoredOIDCClient, Error> = .success(makeDefaultStoredClient())
    var nextStartDeviceAuthorizationResult: Result<(deviceCode: String, verification: DeviceVerification), Error> =
        .success(("stub-device-code", makeDefaultDeviceVerification()))
    var nextCreateTokenResult: Result<StoredSSOToken, Error> = .success(makeDefaultSSOToken())
    var nextRefreshResult: Result<StoredSSOToken, Error> = .success(makeDefaultSSOToken())

    /// Optional async block for `refreshToken`. When set, overrides `nextRefreshResult`.
    /// Useful for tests that need the refresh to block indefinitely (e.g. testing in-flight guards).
    var refreshBlock: (@Sendable () async throws -> StoredSSOToken)?

    // MARK: - Call counts

    private(set) var registerCallCount = 0
    private(set) var startDeviceAuthorizationCallCount = 0
    private(set) var createTokenCallCount = 0
    private(set) var refreshCallCount = 0

    // MARK: - Configuration helpers

    func setNextRefreshResult(_ result: Result<StoredSSOToken, Error>) {
        nextRefreshResult = result
        refreshBlock = nil
    }

    func setNextRefreshBlock(_ block: @escaping @Sendable () async throws -> StoredSSOToken) {
        refreshBlock = block
    }

    // MARK: - OIDCRequesting

    func registerClient(clientName: String, scopes: [String]) async throws -> StoredOIDCClient {
        registerCallCount += 1
        return try nextRegisterResult.get()
    }

    func startDeviceAuthorization(
        client: StoredOIDCClient,
        startUrl: URL,
        sessionName: String
    ) async throws -> (deviceCode: String, verification: DeviceVerification) {
        startDeviceAuthorizationCallCount += 1
        return try nextStartDeviceAuthorizationResult.get()
    }

    func createToken(
        client: StoredOIDCClient,
        deviceCode: String,
        sessionName: String
    ) async throws -> StoredSSOToken {
        createTokenCallCount += 1
        return try nextCreateTokenResult.get()
    }

    func refreshToken(
        client: StoredOIDCClient,
        refreshToken: String,
        sessionName: String
    ) async throws -> StoredSSOToken {
        refreshCallCount += 1
        if let block = refreshBlock {
            return try await block()
        }
        return try nextRefreshResult.get()
    }
}

// MARK: - Default values

private func makeDefaultStoredClient() -> StoredOIDCClient {
    StoredOIDCClient(
        clientId: "stub-client-id",
        clientSecret: "stub-client-secret",
        issuedAt: Date(),
        secretExpiresAt: Date().addingTimeInterval(90 * 24 * 60 * 60),
        region: "us-east-1",
        scopes: ["sso:account:access"]
    )
}

private func makeDefaultDeviceVerification() -> DeviceVerification {
    DeviceVerification(
        userCode: "STUB-CODE",
        verificationUri: URL(string: "https://device.sso.us-east-1.amazonaws.com/")!,
        verificationUriComplete: URL(string: "https://device.sso.us-east-1.amazonaws.com/?user_code=STUB-CODE")!,
        expiresAt: Date().addingTimeInterval(600),
        interval: 1
    )
}

func makeDefaultSSOToken(
    accessToken: String = "stub-access-token",
    refreshToken: String? = "stub-refresh-token",
    sessionName: String = "s",
    expiresIn: TimeInterval = 8 * 3600
) -> StoredSSOToken {
    StoredSSOToken(
        accessToken: accessToken,
        expiresAt: Date().addingTimeInterval(expiresIn),
        refreshToken: refreshToken,
        issuedAt: Date(),
        region: "us-east-1",
        sessionName: sessionName
    )
}
