import Foundation
import Testing
import IAMIdentityCenter
@testable import quorra

@MainActor
struct CredentialsModelTests {
    @Test func verificationHandlerPopulatesInFlight() async throws {
        let stub = StubIdentityCenterService()
        let verification = DeviceVerification(
            userCode: "ABCD-1234",
            verificationUri: URL(string: "https://example.com/device")!,
            verificationUriComplete: URL(string: "https://example.com/device?code=ABCD-1234")!,
            expiresAt: Date().addingTimeInterval(300),
            interval: 5
        )
        await stub.setVerificationToFire(verification)
        await stub.setHoldAfterVerification(true)
        await stub.setSignInResult(.success(StoredSSOToken(
            accessToken: "token",
            expiresAt: Date().addingTimeInterval(3600),
            refreshToken: nil,
            issuedAt: Date(),
            region: "us-east-1",
            sessionName: "test-session"
        )))

        let model = CredentialsModel(service: stub)

        let signInTask = Task {
            await model.signIn(
                sessionName: "test-session",
                startUrl: URL(string: "https://example.com")!,
                region: "us-east-1",
                scopes: ["sso:account:access"]
            )
        }

        await stub.awaitVerificationFired()

        #expect(model.inFlight["test-session"] != nil)
        #expect(model.inFlight["test-session"]?.userCode == "ABCD-1234")

        await stub.releaseHold()
        await signInTask.value
    }

    @Test func successRemovesInFlightAndClearsLastError() async throws {
        let stub = StubIdentityCenterService()
        await stub.setVerificationToFire(DeviceVerification(
            userCode: "ABCD-1234",
            verificationUri: URL(string: "https://example.com/device")!,
            verificationUriComplete: URL(string: "https://example.com/device?code=ABCD-1234")!,
            expiresAt: Date().addingTimeInterval(300),
            interval: 5
        ))
        await stub.setSignInResult(.success(StoredSSOToken(
            accessToken: "token",
            expiresAt: Date().addingTimeInterval(3600),
            refreshToken: nil,
            issuedAt: Date(),
            region: "us-east-1",
            sessionName: "test-session"
        )))

        let model = CredentialsModel(service: stub)
        // Simulate a prior error that should be cleared on the new attempt.
        model.seedLastErrorForTesting(.accessDenied, sessionName: "test-session")

        await model.signIn(
            sessionName: "test-session",
            startUrl: URL(string: "https://example.com")!,
            region: "us-east-1",
            scopes: ["sso:account:access"]
        )

        #expect(model.inFlight["test-session"] == nil)
        #expect(model.lastError["test-session"] == nil)
    }

    @Test func failureStoresLastErrorAndRemovesInFlight() async throws {
        let stub = StubIdentityCenterService()
        await stub.setVerificationToFire(DeviceVerification(
            userCode: "ABCD-1234",
            verificationUri: URL(string: "https://example.com/device")!,
            verificationUriComplete: URL(string: "https://example.com/device?code=ABCD-1234")!,
            expiresAt: Date().addingTimeInterval(300),
            interval: 5
        ))
        await stub.setSignInResult(.failure(.userCancelled))

        let model = CredentialsModel(service: stub)

        await model.signIn(
            sessionName: "test-session",
            startUrl: URL(string: "https://example.com")!,
            region: "us-east-1",
            scopes: ["sso:account:access"]
        )

        #expect(model.inFlight["test-session"] == nil)
        if case .userCancelled = model.lastError["test-session"] {
            // expected
        } else {
            Issue.record("Expected .userCancelled, got \(String(describing: model.lastError["test-session"]))")
        }
    }

    @Test func cancelSignInForwardsToActor() async throws {
        let stub = StubIdentityCenterService()
        let model = CredentialsModel(service: stub)

        await model.cancelSignIn(sessionName: "test-session")

        #expect(await stub.cancelCallCount == 1)
    }

    @Test func lastTokenPopulatedOnSuccess() async throws {
        let stub = StubIdentityCenterService()
        let expectedExpiry = Date().addingTimeInterval(3600)
        await stub.setVerificationToFire(DeviceVerification(
            userCode: "ABCD-1234",
            verificationUri: URL(string: "https://example.com/device")!,
            verificationUriComplete: URL(string: "https://example.com/device?code=ABCD-1234")!,
            expiresAt: Date().addingTimeInterval(300),
            interval: 5
        ))
        await stub.setSignInResult(.success(StoredSSOToken(
            accessToken: "token",
            expiresAt: expectedExpiry,
            refreshToken: nil,
            issuedAt: Date(),
            region: "us-east-1",
            sessionName: "test-session"
        )))

        let model = CredentialsModel(service: stub)

        await model.signIn(
            sessionName: "test-session",
            startUrl: URL(string: "https://example.com")!,
            region: "us-east-1",
            scopes: ["sso:account:access"]
        )

        #expect(model.lastToken["test-session"]?.accessToken == "token")
        #expect(model.lastToken["test-session"]?.expiresAt == expectedExpiry)
    }

    @Test func startingNewSignInClearsPriorLastToken() async throws {
        let stub = StubIdentityCenterService()
        await stub.setVerificationToFire(DeviceVerification(
            userCode: "ABCD-1234",
            verificationUri: URL(string: "https://example.com/device")!,
            verificationUriComplete: URL(string: "https://example.com/device?code=ABCD-1234")!,
            expiresAt: Date().addingTimeInterval(300),
            interval: 5
        ))
        await stub.setHoldAfterVerification(true)
        await stub.setSignInResult(.success(StoredSSOToken(
            accessToken: "token",
            expiresAt: Date().addingTimeInterval(3600),
            refreshToken: nil,
            issuedAt: Date(),
            region: "us-east-1",
            sessionName: "test-session"
        )))

        let model = CredentialsModel(service: stub)
        model.seedLastTokenForTesting(
            StoredSSOToken(
                accessToken: "old-token",
                expiresAt: Date().addingTimeInterval(7200),
                refreshToken: nil,
                issuedAt: Date(),
                region: "us-east-1",
                sessionName: "test-session"
            ),
            sessionName: "test-session"
        )

        let signInTask = Task {
            await model.signIn(
                sessionName: "test-session",
                startUrl: URL(string: "https://example.com")!,
                region: "us-east-1",
                scopes: ["sso:account:access"]
            )
        }

        await stub.awaitVerificationFired()

        #expect(model.lastToken["test-session"] == nil)

        await stub.releaseHold()
        await signInTask.value
    }

    @Test func failureDoesNotPopulateLastToken() async throws {
        let stub = StubIdentityCenterService()
        await stub.setVerificationToFire(DeviceVerification(
            userCode: "ABCD-1234",
            verificationUri: URL(string: "https://example.com/device")!,
            verificationUriComplete: URL(string: "https://example.com/device?code=ABCD-1234")!,
            expiresAt: Date().addingTimeInterval(300),
            interval: 5
        ))
        await stub.setSignInResult(.failure(.userCancelled))

        let model = CredentialsModel(service: stub)

        await model.signIn(
            sessionName: "test-session",
            startUrl: URL(string: "https://example.com")!,
            region: "us-east-1",
            scopes: ["sso:account:access"]
        )

        #expect(model.lastToken["test-session"] == nil)
        if case .userCancelled = model.lastError["test-session"] {
            // expected
        } else {
            Issue.record("Expected .userCancelled, got \(String(describing: model.lastError["test-session"]))")
        }
    }

    @Test func startingNewSignInClearsPriorLastError() async throws {
        let stub = StubIdentityCenterService()
        await stub.setVerificationToFire(DeviceVerification(
            userCode: "ABCD-1234",
            verificationUri: URL(string: "https://example.com/device")!,
            verificationUriComplete: URL(string: "https://example.com/device?code=ABCD-1234")!,
            expiresAt: Date().addingTimeInterval(300),
            interval: 5
        ))
        await stub.setHoldAfterVerification(true)
        await stub.setSignInResult(.success(StoredSSOToken(
            accessToken: "token",
            expiresAt: Date().addingTimeInterval(3600),
            refreshToken: nil,
            issuedAt: Date(),
            region: "us-east-1",
            sessionName: "test-session"
        )))

        let model = CredentialsModel(service: stub)
        model.seedLastErrorForTesting(.accessDenied, sessionName: "test-session")

        let signInTask = Task {
            await model.signIn(
                sessionName: "test-session",
                startUrl: URL(string: "https://example.com")!,
                region: "us-east-1",
                scopes: ["sso:account:access"]
            )
        }

        await stub.awaitVerificationFired()

        #expect(model.lastError["test-session"] == nil)

        await stub.releaseHold()
        await signInTask.value
    }
}

/// Actor-backed stub conforming to `IdentityCenterServicing`. Tests use the continuation
/// helpers (`awaitVerificationFired`, `releaseHold`) to synchronize on flow events instead of
/// real `Task.sleep`.
actor StubIdentityCenterService: IdentityCenterServicing {
    var signInResult: Result<StoredSSOToken, IAMIdentityCenterError>?
    var verificationToFire: DeviceVerification?
    var holdAfterVerification = false
    private(set) var signInCallCount = 0
    private(set) var cancelCallCount = 0
    private var verificationFiredContinuations: [CheckedContinuation<Void, Never>] = []
    private var verificationHasFired = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func setSignInResult(_ result: Result<StoredSSOToken, IAMIdentityCenterError>) {
        signInResult = result
    }

    func setVerificationToFire(_ verification: DeviceVerification) {
        verificationToFire = verification
    }

    func setHoldAfterVerification(_ hold: Bool) {
        holdAfterVerification = hold
    }

    func signIn(
        sessionName: String,
        startUrl: URL,
        region: String,
        scopes: [String],
        clientName: String,
        verificationHandler: @escaping @concurrent @Sendable (DeviceVerification) async -> Void
    ) async throws -> StoredSSOToken {
        signInCallCount += 1
        let verification = verificationToFire
        let shouldHold = holdAfterVerification

        if let v = verification {
            await verificationHandler(v)
            verificationHasFired = true
            let waiters = verificationFiredContinuations
            verificationFiredContinuations.removeAll()
            for c in waiters { c.resume() }
        }

        if shouldHold {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                releaseContinuation = c
            }
        }

        switch signInResult {
        case .success(let token): return token
        case .failure(let error): throw error
        case .none:
            throw IAMIdentityCenterError.malformedResponse("test stub had no result")
        }
    }

    func cancelSignIn(sessionName: String) async {
        cancelCallCount += 1
    }

    /// Suspends until the verification handler has fired at least once.
    func awaitVerificationFired() async {
        if verificationHasFired { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            verificationFiredContinuations.append(c)
        }
    }

    /// Releases a hold installed via `holdAfterVerification`.
    func releaseHold() {
        let c = releaseContinuation
        releaseContinuation = nil
        c?.resume()
    }
}
