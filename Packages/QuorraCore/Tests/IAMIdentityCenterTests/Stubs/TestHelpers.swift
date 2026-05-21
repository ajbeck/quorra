import Foundation
@testable import IAMIdentityCenter

/// Actor-isolated collector for `AuthEvent`s. Captures events from `Task` closures
/// without introducing a shared mutable `var` that would violate Swift 6 Sendable rules.
actor EventCollector {
    private(set) var events: [AuthEvent] = []

    func append(_ event: AuthEvent) {
        events.append(event)
    }
}

/// Actor-isolated integer counter, for tests that only need to know how many events arrived.
actor EventCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

// MARK: - Test-only IdentityCenterService helpers

extension IdentityCenterService {
    /// Test-only: directly injects a task into `inFlightRefresh` without going through the
    /// real refresh code path. Used to set up the precondition for `handleRefresh` no-op tests.
    func _test_setInFlightRefresh(_ task: Task<StoredSSOToken, Error>, for sessionName: String) {
        inFlightRefresh[sessionName] = task
    }
}

// MARK: - OIDC provider helpers

/// Wraps a single `StubOIDCRequesting` in a `StubOIDCClientProvider` that returns the same
/// stub for every region. Use this when a test doesn't care about region routing and just
/// wants the actor to receive the stub it's set up.
func makeStubOIDCProvider(_ stub: StubOIDCRequesting) -> StubOIDCClientProvider {
    StubOIDCClientProvider(factory: { _ in stub })
}

/// Builds a `StoredOIDCClient` for stub `registerClient` results.
func makeStoredClient(
    clientId: String = "test-client-id",
    clientSecret: String = "test-client-secret",
    region: String = "us-east-1",
    secretExpiresAt: Date = Date().addingTimeInterval(90 * 24 * 60 * 60),
    scopes: [String] = ["sso:account:access"]
) -> StoredOIDCClient {
    StoredOIDCClient(
        clientId: clientId,
        clientSecret: clientSecret,
        issuedAt: Date(),
        secretExpiresAt: secretExpiresAt,
        region: region,
        scopes: scopes
    )
}

/// Builds a `DeviceVerification` for stub `startDeviceAuthorization` results.
func makeVerification(
    userCode: String = "ABCD-1234",
    interval: TimeInterval = 1,
    expiresIn: TimeInterval = 600
) -> DeviceVerification {
    DeviceVerification(
        userCode: userCode,
        verificationUri: URL(string: "https://device.sso.us-east-1.amazonaws.com/")!,
        verificationUriComplete: URL(string: "https://device.sso.us-east-1.amazonaws.com/?user_code=\(userCode)")!,
        expiresAt: Date().addingTimeInterval(expiresIn),
        interval: interval
    )
}

// MARK: - StubURLProtocol wire helpers

/// Registers a successful `RegisterClient` response for the test's stubbed URLSession.
func registerStub(
    clientId: String = "test-client-id",
    clientSecret: String = "test-client-secret"
) throws {
    try StubURLProtocol.registerSuccess(urlSubstring: "/client/register", json: [
        "clientId": clientId,
        "clientSecret": clientSecret,
        "clientIdIssuedAt": Int(Date().timeIntervalSince1970),
        "clientSecretExpiresAt": Int(Date().addingTimeInterval(90 * 24 * 60 * 60).timeIntervalSince1970),
    ])
}

/// Registers a successful `StartDeviceAuthorization` response.
func deviceAuthStub(expiresIn: Int = 600, interval: Int = 5) throws {
    try StubURLProtocol.registerSuccess(urlSubstring: "/device_authorization", json: [
        "deviceCode": "test-device-code",
        "userCode": "ABCD-1234",
        "verificationUri": "https://device.sso.us-east-1.amazonaws.com/",
        "verificationUriComplete": "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-1234",
        "expiresIn": expiresIn,
        "interval": interval,
    ])
}
