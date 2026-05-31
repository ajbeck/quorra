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

    @Test func signedInEventRefreshesStatusCache() async throws {
        let stub = StubIdentityCenterService()
        let expiresAt = Date().addingTimeInterval(3600)
        await stub.setStatusToReturn(.signedIn(expiresAt: expiresAt, canRefresh: false))
        let model = CredentialsModel(service: stub)

        await model.processEventForTesting(.signedIn(sessionName: "test-session"))

        // The model should have fetched status and populated the cache
        if case .signedIn = model.status["test-session"] {
            // expected
        } else {
            Issue.record("Expected .signedIn status after stream event, got \(String(describing: model.status["test-session"]))")
        }
    }

    @Test func signedInEventRefreshesObservedProfileStatuses() async throws {
        let stub = StubIdentityCenterService()
        let expiresAt = Date().addingTimeInterval(3600)
        await stub.setStatusToReturn(.signedIn(expiresAt: expiresAt, canRefresh: false))
        await stub.setProfileStatusToReturn(.ready(expiresAt: expiresAt))
        let model = CredentialsModel(service: stub)
        let key = "session-a:111111111111:r1"

        model.seedProfileStatusForTesting(.signInExpired(sessionName: "session-a"), key: key)

        await model.processEventForTesting(.signedIn(sessionName: "session-a"))

        if case .ready = model.profileStatus[key] {
            // expected
        } else {
            Issue.record("Expected observed profile status to refresh to .ready after sign-in, got \(String(describing: model.profileStatus[key]))")
        }
    }

    @Test func expiredEventRefreshesObservedProfileStatusesForSessionOnly() async throws {
        let stub = StubIdentityCenterService()
        await stub.setStatusToReturn(.expired(expiredAt: Date().addingTimeInterval(-60), canRefresh: false))
        await stub.setProfileStatusToReturn(.signInExpired(sessionName: "session-a"))
        let model = CredentialsModel(service: stub)
        let keyA1 = "session-a:111111111111:r1"
        let keyA2 = "session-a:222222222222:r2"
        let keyB = "session-b:333333333333:r3"

        model.seedProfileStatusForTesting(.ready(expiresAt: Date().addingTimeInterval(3600)), key: keyA1)
        model.seedProfileStatusForTesting(.ready(expiresAt: Date().addingTimeInterval(3600)), key: keyA2)
        model.seedProfileStatusForTesting(.ready(expiresAt: Date().addingTimeInterval(3600)), key: keyB)

        await model.processEventForTesting(.expired(sessionName: "session-a"))

        #expect(model.profileStatus[keyA1] == .signInExpired(sessionName: "session-a"))
        #expect(model.profileStatus[keyA2] == .signInExpired(sessionName: "session-a"))
        if case .ready = model.profileStatus[keyB] {
            // expected: other sessions are untouched
        } else {
            Issue.record("Expected unrelated profile status to stay .ready, got \(String(describing: model.profileStatus[keyB]))")
        }
    }

    @Test func signOutFailureEventSetsAdvisory() async throws {
        let stub = StubIdentityCenterService()
        let model = CredentialsModel(service: stub)

        #expect(!model.signOutFailure.contains("test-session"))

        await model.processEventForTesting(.signOutServerSideFailed(sessionName: "test-session"))

        #expect(model.signOutFailure.contains("test-session"))
    }

    // MARK: - B (D30) mint event → overlay mapping

    @Test func mintingCredentialsEventPopulatesMintingNow() async throws {
        let stub = StubIdentityCenterService()
        await stub.setProfileStatusToReturn(.ready(expiresAt: Date().addingTimeInterval(3600)))
        let model = CredentialsModel(service: stub)
        let key = "s:123456789012:r"

        // Seed prior failure/rejected state so we can prove .mintingCredentials clears them.
        model.seedMintFailureForTesting(key: key)
        model.seedRoleRejectedForTesting(key: key)

        await model.processEventForTesting(.mintingCredentials(sessionName: "s", accountId: "123456789012", roleName: "r"))

        #expect(model.mintingNow.contains(key))
        #expect(!model.mintFailure.contains(key))
        #expect(!model.roleRejected.contains(key))
    }

    @Test func mintedCredentialsEventClearsAllBSets() async throws {
        let stub = StubIdentityCenterService()
        await stub.setProfileStatusToReturn(.ready(expiresAt: Date().addingTimeInterval(3600)))
        let model = CredentialsModel(service: stub)
        let key = "s:123456789012:r"

        model.seedMintingNowForTesting(key: key)
        model.seedMintFailureForTesting(key: key)
        model.seedRoleRejectedForTesting(key: key)

        await model.processEventForTesting(.mintedCredentials(sessionName: "s", accountId: "123456789012", roleName: "r"))

        #expect(!model.mintingNow.contains(key))
        #expect(!model.mintFailure.contains(key))
        #expect(!model.roleRejected.contains(key))
    }

    @Test func mintCredentialsFailedEventSetsMintFailure() async throws {
        let stub = StubIdentityCenterService()
        let model = CredentialsModel(service: stub)
        let key = "s:123456789012:r"

        model.seedMintingNowForTesting(key: key)

        await model.processEventForTesting(.mintCredentialsFailed(sessionName: "s", accountId: "123456789012", roleName: "r"))

        #expect(!model.mintingNow.contains(key))
        #expect(model.mintFailure.contains(key))
    }

    @Test func roleAccessDeniedEventSetsRoleRejected() async throws {
        let stub = StubIdentityCenterService()
        await stub.setProfileStatusToReturn(.ready(expiresAt: nil))
        let model = CredentialsModel(service: stub)
        let key = "s:123456789012:r"

        model.seedMintingNowForTesting(key: key)

        await model.processEventForTesting(.roleAccessDenied(sessionName: "s", accountId: "123456789012", roleName: "r"))

        #expect(!model.mintingNow.contains(key))
        #expect(model.roleRejected.contains(key))
    }

    @Test func signedOutClearsBSetsForSessionPrefixOnly() async throws {
        let stub = StubIdentityCenterService()
        let model = CredentialsModel(service: stub)
        let keyA1 = "session-a:111111111111:r1"
        let keyA2 = "session-a:222222222222:r2"
        let keyB = "session-b:333333333333:r3"

        model.seedProfileStatusForTesting(.ready(expiresAt: Date().addingTimeInterval(3600)), key: keyA1)
        model.seedProfileStatusForTesting(.ready(expiresAt: Date().addingTimeInterval(3600)), key: keyB)
        model.seedMintingNowForTesting(key: keyA1)
        model.seedMintFailureForTesting(key: keyA2)
        model.seedRoleRejectedForTesting(key: keyA1)
        model.seedRoleRejectedForTesting(key: keyB)

        await model.processEventForTesting(.signedOut(sessionName: "session-a"))

        // session-a keys cleared from every B set
        #expect(!model.mintingNow.contains(keyA1))
        #expect(!model.mintFailure.contains(keyA2))
        #expect(!model.roleRejected.contains(keyA1))
        // session-b key untouched (prefix isolation)
        #expect(model.roleRejected.contains(keyB))
        #expect(model.profileStatus[keyA1] == .notSignedIn(sessionName: "session-a"))
        if case .ready = model.profileStatus[keyB] {
            // expected
        } else {
            Issue.record("Expected unrelated profile status to stay .ready, got \(String(describing: model.profileStatus[keyB]))")
        }
        #expect(model.status["session-a"] == .signedOut)
    }

    // MARK: - observeProfileStatus populates the profileStatus cache

    @Test func observeProfileStatusPopulatesCache() async {
        let stub = StubIdentityCenterService()
        await stub.setProfileStatusToReturn(.ready(expiresAt: Date().addingTimeInterval(3600)))
        let model = CredentialsModel(service: stub)
        let key = "s:123456789012:r"

        #expect(model.profileStatus[key] == nil)

        await model.observeProfileStatus(forSession: "s", accountId: "123456789012", roleName: "r")

        if case .ready = model.profileStatus[key] {
            // expected — populated from the stub
        } else {
            Issue.record("Expected .ready in profileStatus cache, got \(String(describing: model.profileStatus[key]))")
        }
    }
}

/// Actor-backed stub conforming to `IdentityCenterServicing`. Sign-in tests use continuation
/// helpers (`awaitVerificationFired`, `releaseHold`) to synchronize on flow progress.
actor StubIdentityCenterService: IdentityCenterServicing {
    var signInResult: Result<StoredSSOToken, IAMIdentityCenterError>?
    var verificationToFire: DeviceVerification?
    var holdAfterVerification = false
    private(set) var signInCallCount = 0
    private(set) var cancelCallCount = 0
    private(set) var signOutCallCount = 0
    private var statusToReturn: SessionAuthStatus = .signedOut
    private var profileStatusToReturn: ProfileAuthStatus = .notSignedIn(sessionName: "stub")
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

    func setProfileStatusToReturn(_ status: ProfileAuthStatus) {
        profileStatusToReturn = status
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

    @concurrent
    func status(
        forProfile sessionName: String,
        accountId: String,
        roleName: String
    ) async -> ProfileAuthStatus {
        await self.getProfileStatus()
    }

    private func getProfileStatus() -> ProfileAuthStatus {
        profileStatusToReturn
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
