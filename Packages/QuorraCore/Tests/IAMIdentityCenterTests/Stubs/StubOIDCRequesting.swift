import Foundation
@testable import IAMIdentityCenter

/// Actor-based test double for `OIDCRequesting`.
///
/// The single OIDC test seam: injected through the `OIDCClientProviding` provider so the actor
/// exercises real behavior (refresh outcome, sign-out sequencing, session lock) against canned
/// results. Wire encoding is owned by the AWS SDK and is not tested here (Apple: test the code
/// you own, not your dependencies).
///
/// Usage:
/// ```swift
/// let stub = StubOIDCRequesting()
/// await stub.setNextRefreshResult(.success(newToken))
/// let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(stub))
/// ```
actor StubOIDCRequesting: OIDCRequesting {

    /// Builds a stub whose default `registerClient` result carries `registerRegion`.
    ///
    /// In production `SDKOIDCClient.registerClient` embeds the client's region into the
    /// returned `StoredOIDCClient`, and the actor's `pollForToken` keys its provider lookup
    /// off `client.region`. So a region-faithful stub (built with the region it's vended for)
    /// keeps every provider lookup on the same region — matching real behavior.
    init(registerRegion: String = "us-east-1") {
        self.nextRegisterResult = .success(makeDefaultStoredClient(region: registerRegion))
    }

    // MARK: - Canned results (set per-test)

    var nextRegisterResult: Result<StoredOIDCClient, Error>
    var nextStartDeviceAuthorizationResult: Result<(deviceCode: String, verification: DeviceVerification), Error> =
        .success(("stub-device-code", makeDefaultDeviceVerification()))
    var nextCreateTokenResult: Result<StoredSSOToken, Error> = .success(makeDefaultSSOToken())
    var nextRefreshResult: Result<StoredSSOToken, Error> = .success(makeDefaultSSOToken())

    /// Optional async block for `startDeviceAuthorization`. When set, overrides
    /// `nextStartDeviceAuthorizationResult`. Useful for tests that need to vary behavior across
    /// calls (e.g. fail once with `.invalidClient`, then succeed after re-registration).
    var startDeviceAuthorizationBlock: (@Sendable () async throws -> (deviceCode: String, verification: DeviceVerification))?

    /// Optional async block for `createToken`. When set, overrides `nextCreateTokenResult`.
    /// Useful for tests that need the token poll to block indefinitely (e.g. cancellation tests).
    var createTokenBlock: (@Sendable () async throws -> StoredSSOToken)?

    /// Optional async block for `refreshToken`. When set, overrides `nextRefreshResult`.
    /// Useful for tests that need the refresh to block indefinitely (e.g. testing in-flight guards).
    var refreshBlock: (@Sendable () async throws -> StoredSSOToken)?

    // MARK: - Call counts

    private(set) var registerCallCount = 0
    private(set) var startDeviceAuthorizationCallCount = 0
    private(set) var createTokenCallCount = 0
    private(set) var refreshCallCount = 0

    // MARK: - Configuration helpers

    func setNextRegisterResult(_ result: Result<StoredOIDCClient, Error>) {
        nextRegisterResult = result
    }

    func setNextStartDeviceAuthorizationResult(
        _ result: Result<(deviceCode: String, verification: DeviceVerification), Error>
    ) {
        nextStartDeviceAuthorizationResult = result
    }

    func setStartDeviceAuthorizationBlock(
        _ block: @escaping @Sendable () async throws -> (deviceCode: String, verification: DeviceVerification)
    ) {
        startDeviceAuthorizationBlock = block
    }

    func setNextCreateTokenResult(_ result: Result<StoredSSOToken, Error>) {
        nextCreateTokenResult = result
        createTokenBlock = nil
    }

    func setCreateTokenBlock(_ block: @escaping @Sendable () async throws -> StoredSSOToken) {
        createTokenBlock = block
        nextCreateTokenResult = .success(makeDefaultSSOToken())  // reset canned result
    }

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
        if let block = startDeviceAuthorizationBlock {
            return try await block()
        }
        return try nextStartDeviceAuthorizationResult.get()
    }

    func createToken(
        client: StoredOIDCClient,
        deviceCode: String,
        sessionName: String
    ) async throws -> StoredSSOToken {
        createTokenCallCount += 1
        if let block = createTokenBlock {
            return try await block()
        }
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

private func makeDefaultStoredClient(region: String = "us-east-1") -> StoredOIDCClient {
    StoredOIDCClient(
        clientId: "stub-client-id",
        clientSecret: "stub-client-secret",
        issuedAt: Date(),
        secretExpiresAt: Date().addingTimeInterval(90 * 24 * 60 * 60),
        region: region,
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
