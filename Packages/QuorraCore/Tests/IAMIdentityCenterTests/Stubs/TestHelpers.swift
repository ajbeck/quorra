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
