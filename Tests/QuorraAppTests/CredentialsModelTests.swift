import Foundation
import Testing
import IAMIdentityCenter
@testable import quorra

@MainActor
struct CredentialsModelTests {

    // MARK: - verificationHandler populates inFlight

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

    // MARK: - Success clears inFlight and lastError

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

    // MARK: - Failure stores lastError and clears inFlight

    @Test func failureStoresLastErrorAndRemovesInFlight() async throws {
        let stub = StubIdentityCenterService()
        await stub.setVerificationToFire(DeviceVerification(
            userCode: "ABCD-1234",
            verificationUri: URL(string: "https://example.com/device")!,
            verificationUriComplete: URL(string: "https://example.com/device?code=ABCD-1234")!,
            expiresAt: Date().addingTimeInterval(300),
            interval: 5
        ))
        await stub.setSignInResult(.failure(.expiredDeviceCode))

        let model = CredentialsModel(service: stub)

        await model.signIn(
            sessionName: "test-session",
            startUrl: URL(string: "https://example.com")!,
            region: "us-east-1",
            scopes: ["sso:account:access"]
        )

        #expect(model.inFlight["test-session"] == nil)
        #expect(model.lastError["test-session"] == .expiredDeviceCode)
    }

    // MARK: - cancelSignIn forwards to service

    @Test func cancelSignInForwardsToActor() async throws {
        let stub = StubIdentityCenterService()
        let model = CredentialsModel(service: stub)

        await model.cancelSignIn(sessionName: "test-session")

        #expect(await stub.cancelCallCount == 1)
    }

    // MARK: - userCancelled does NOT populate lastError

    @Test func userCancelledDoesNotStoreLastError() async throws {
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
        // userCancelled is the only error that should NOT be stored in lastError
        #expect(model.lastError["test-session"] == nil)
    }

    // MARK: - startingNewSignIn clears prior lastError

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

    // MARK: - observeStatus populates status cache

    @Test func observeStatusPopulatesCache() async {
        let stub = StubIdentityCenterService()
        await stub.setStatusToReturn(.signedIn(expiresAt: Date().addingTimeInterval(3600), canRefresh: false))
        let model = CredentialsModel(service: stub)

        #expect(model.status["my-session"] == nil)

        await model.observeStatus(forSession: "my-session")

        // expiresAt will differ slightly between the stub and the model; check the case.
        if case .signedIn = model.status["my-session"] {
            // expected — status was populated from the stub
        } else {
            Issue.record("Expected .signedIn status after observeStatus, got \(String(describing: model.status["my-session"]))")
        }
    }

    @Test func observeStatusCachePopulatedWithSignedOut() async {
        let stub = StubIdentityCenterService()
        // default status is .signedOut
        let model = CredentialsModel(service: stub)

        await model.observeStatus(forSession: "my-session")

        #expect(model.status["my-session"] == .signedOut)
    }

    // MARK: - signOut delegates to service

    @Test func signOutDelegatesToService() async throws {
        let stub = StubIdentityCenterService()
        let model = CredentialsModel(service: stub)

        await model.signOut(sessionName: "test-session")

        #expect(await stub.signOutCallCount == 1)
    }

    // MARK: - signOutFailure set on event, cleared on next signIn

    @Test func signOutFailureSetOnEventAndClearedOnNextSignIn() async throws {
        let stub = StubIdentityCenterService()
        let model = CredentialsModel(service: stub)

        // Seed the signOutFailure advisory via the test seam
        model.seedSignOutFailureForTesting(sessionName: "test-session")
        #expect(model.signOutFailure.contains("test-session"))

        // Starting a new signIn should clear the advisory
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

        await model.signIn(
            sessionName: "test-session",
            startUrl: URL(string: "https://example.com")!,
            region: "us-east-1",
            scopes: ["sso:account:access"]
        )

        #expect(!model.signOutFailure.contains("test-session"))
    }

    // MARK: - stream consumer updates status on events

    @Test func streamConsumerUpdatesStatusOnSignedInEvent() async throws {
        let stub = StubIdentityCenterService()
        let expiresAt = Date().addingTimeInterval(3600)
        await stub.setStatusToReturn(.signedIn(expiresAt: expiresAt, canRefresh: false))
        let model = CredentialsModel(service: stub)

        // Yield a .signedIn event from the stub's stream
        await stub.yieldEvent(.signedIn(sessionName: "test-session"))

        // The event consumer Task hops: stream → handleEvent → refreshStatus → service.status (actor)
        // → model.status update. Multiple async hops require a brief sleep rather than Task.yield().
        // Apple: Swift/TaskGroup/Task.sleep(for:) — smallest reliable async wait for testing.
        try await Task.sleep(for: .milliseconds(100))

        // The model should have fetched status and populated the cache
        if case .signedIn = model.status["test-session"] {
            // expected
        } else {
            Issue.record("Expected .signedIn status after stream event, got \(String(describing: model.status["test-session"]))")
        }
    }

    @Test func streamConsumerSetsSignOutFailureOnEvent() async throws {
        let stub = StubIdentityCenterService()
        let model = CredentialsModel(service: stub)

        #expect(!model.signOutFailure.contains("test-session"))

        await stub.yieldEvent(.signOutServerSideFailed(sessionName: "test-session"))

        // Give the event consumer Task time to process across async hops
        try await Task.sleep(for: .milliseconds(100))

        #expect(model.signOutFailure.contains("test-session"))
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
    private(set) var signOutCallCount = 0
    private var statusToReturn: SessionAuthStatus = .signedOut
    private var verificationFiredContinuations: [CheckedContinuation<Void, Never>] = []
    private var verificationHasFired = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    // Apple: Swift/AsyncStream/makeStream(of:bufferingPolicy:) — creates a controllable stream for tests
    private let streamContinuation: AsyncStream<AuthEvent>.Continuation
    nonisolated let events: AsyncStream<AuthEvent>

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: AuthEvent.self)
        self.events = stream
        self.streamContinuation = continuation
    }

    func setSignInResult(_ result: Result<StoredSSOToken, IAMIdentityCenterError>) {
        signInResult = result
    }

    func setVerificationToFire(_ verification: DeviceVerification) {
        verificationToFire = verification
    }

    func setHoldAfterVerification(_ hold: Bool) {
        holdAfterVerification = hold
    }

    func setStatusToReturn(_ status: SessionAuthStatus) {
        statusToReturn = status
    }

    /// Yields an event to the stream so the CredentialsModel's consumer Task processes it.
    func yieldEvent(_ event: AuthEvent) {
        streamContinuation.yield(event)
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

    @concurrent
    func status(forSession sessionName: String) async -> SessionAuthStatus {
        await self.getStatus()
    }

    private func getStatus() -> SessionAuthStatus {
        statusToReturn
    }

    @concurrent
    func signOut(sessionName: String) async throws {
        await self.recordSignOut()
    }

    private func recordSignOut() {
        signOutCallCount += 1
    }

    @concurrent
    func liveToken(forSession sessionName: String) async throws -> StoredSSOToken {
        throw IAMIdentityCenterError.notSignedIn
    }

    @concurrent
    func refreshNow(sessionName: String) async throws -> StoredSSOToken {
        throw IAMIdentityCenterError.notSignedIn
    }

    @concurrent
    func liveCredentials(
        forSession sessionName: String,
        accountId: String,
        roleName: String,
        region: String
    ) async throws -> RoleCredentials {
        throw IAMIdentityCenterError.notSignedIn
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
