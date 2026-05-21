import Testing
import Foundation
@testable import IAMIdentityCenter

extension IAMIdentityCenterTestSuite {
@Suite("IdentityCenterService.status", .serialized, .timeLimit(.minutes(1)))
struct StatusTests {

    // MARK: - Missing row → .signedOut

    @Test("Missing Keychain row returns .signedOut")
    func missingRow() async {
        let keychain = InMemoryKeychainStore()
        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(StubOIDCRequesting()))

        let result = await service.status(forSession: "no-such-session")
        #expect(result == .signedOut)
    }

    // MARK: - Valid token → .signedIn

    @Test("Valid token returns .signedIn with correct expiresAt and canRefresh=false")
    func validTokenNoRefresh() async throws {
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(3600)
        try await keychain.writeRecord(
            makeToken(expiresAt: expiresAt, refreshToken: nil),
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: "test-session"
        )

        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(StubOIDCRequesting()))

        let result = await service.status(forSession: "test-session")
        if case .signedIn(let at, let canRefresh) = result {
            #expect(abs(at.timeIntervalSince(expiresAt)) < 1)
            #expect(canRefresh == false)
        } else {
            Issue.record("Expected .signedIn, got \(result)")
        }
    }

    @Test("Valid token with refresh token returns .signedIn with canRefresh=true")
    func validTokenWithRefresh() async throws {
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(3600)
        try await keychain.writeRecord(
            makeToken(expiresAt: expiresAt, refreshToken: "refresh-tok"),
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: "test-session"
        )

        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(StubOIDCRequesting()))

        let result = await service.status(forSession: "test-session")
        if case .signedIn(_, let canRefresh) = result {
            #expect(canRefresh == true)
        } else {
            Issue.record("Expected .signedIn, got \(result)")
        }
    }

    // MARK: - Past expiresAt → .expired

    @Test("Token past expiresAt returns .expired with canRefresh=false")
    func expiredTokenNoRefresh() async throws {
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(-60)  // 1 minute ago
        try await keychain.writeRecord(
            makeToken(expiresAt: expiresAt, refreshToken: nil),
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: "test-session"
        )

        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(StubOIDCRequesting()))

        let result = await service.status(forSession: "test-session")
        if case .expired(_, let canRefresh) = result {
            #expect(canRefresh == false)
        } else {
            Issue.record("Expected .expired, got \(result)")
        }
    }

    @Test("Expired token with refresh token returns .expired with canRefresh=true")
    func expiredTokenWithRefresh() async throws {
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(-60)
        try await keychain.writeRecord(
            makeToken(expiresAt: expiresAt, refreshToken: "refresh-tok"),
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: "test-session"
        )

        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(StubOIDCRequesting()))

        let result = await service.status(forSession: "test-session")
        if case .expired(_, let canRefresh) = result {
            #expect(canRefresh == true)
        } else {
            Issue.record("Expected .expired, got \(result)")
        }
    }

    // MARK: - Malformed data → .signedOut (D7)

    @Test("Malformed Keychain data returns .signedOut and doesn't throw")
    func malformedData() async {
        let keychain = InMemoryKeychainStore()
        // Write garbage bytes that won't decode as StoredSSOToken
        await keychain.write(
            Data("not-valid-json".utf8),
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: "test-session"
        )

        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(StubOIDCRequesting()))

        let result = await service.status(forSession: "test-session")
        #expect(result == .signedOut)
    }

    // MARK: - App restart — opportunistic timer schedule

    @Test("First status() on valid token schedules expiration timer (opportunistic restart path)")
    func opportunisticTimerScheduled() async throws {
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(3600)
        try await keychain.writeRecord(
            makeToken(expiresAt: expiresAt, refreshToken: nil),
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: "test-session"
        )

        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(StubOIDCRequesting()))

        // No timer before first status call
        let timerBefore = await service.expirationTimers["test-session"]
        #expect(timerBefore == nil)

        _ = await service.status(forSession: "test-session")

        // Timer scheduled after first status call
        let timerAfter = await service.expirationTimers["test-session"]
        #expect(timerAfter != nil)

        timerAfter?.cancel()
    }

    @Test("status() on expired token does NOT schedule a timer")
    func noTimerOnExpiredToken() async throws {
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(-60)
        try await keychain.writeRecord(
            makeToken(expiresAt: expiresAt, refreshToken: nil),
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: "test-session"
        )

        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(StubOIDCRequesting()))

        _ = await service.status(forSession: "test-session")

        let timer = await service.expirationTimers["test-session"]
        #expect(timer == nil)
    }
}
}

// MARK: - Helpers

private func makeToken(
    expiresAt: Date,
    refreshToken: String?,
    sessionName: String = "test-session"
) -> StoredSSOToken {
    StoredSSOToken(
        accessToken: "test-access-token",
        expiresAt: expiresAt,
        refreshToken: refreshToken,
        issuedAt: Date(),
        region: "us-east-1",
        sessionName: sessionName
    )
}
