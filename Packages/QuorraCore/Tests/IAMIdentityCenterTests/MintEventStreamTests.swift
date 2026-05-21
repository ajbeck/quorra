import Testing
import Foundation
@testable import IAMIdentityCenter

extension IAMIdentityCenterTestSuite {
@Suite("Mint event stream (D30)", .serialized, .timeLimit(.minutes(1)))
struct MintEventStreamTests {

    // MARK: - Helpers

    private func makeService(
        keychain: InMemoryKeychainStore = InMemoryKeychainStore(),
        portal: StubPortalRequesting = StubPortalRequesting()
    ) -> IdentityCenterService {
        return IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(StubOIDCRequesting()), portalClient: portal)
    }

    private func seedFreshToken(keychain: InMemoryKeychainStore, sessionName: String = "s") async throws {
        try await keychain.writeRecord(
            StoredSSOToken(
                accessToken: "at",
                expiresAt: Date().addingTimeInterval(8 * 3600),
                refreshToken: "rt",
                issuedAt: Date(),
                region: "us-east-1",
                sessionName: sessionName
            ),
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: sessionName
        )
    }

    private func collectMintEvents(
        from service: IdentityCenterService,
        until isTerminal: @escaping @Sendable (AuthEvent) -> Bool
    ) -> (EventCollector, Task<Void, Never>) {
        let collector = EventCollector()
        let task = Task {
            for await event in service.events {
                await collector.append(event)
                if isTerminal(event) { break }
            }
        }
        return (collector, task)
    }

    // MARK: - Successful mint → mintingCredentials then mintedCredentials

    @Test("Successful liveCredentials mint emits .mintingCredentials then .mintedCredentials")
    func successEmitsMintingThenMinted() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let portal = StubPortalRequesting()
        try await seedFreshToken(keychain: keychain)
        await portal.setNextGetRoleCredentialsResult(.success(makeDefaultMintedCredential()))
        let service = makeService(keychain: keychain, portal: portal)

        let (collector, collectTask) = collectMintEvents(from: service) {
            if case .mintedCredentials = $0 { return true }
            return false
        }

        _ = try await service.liveCredentials(forSession: "s", accountId: "123456789012", roleName: "r", region: "us-east-1")
        await collectTask.value

        let events = await collector.events
        #expect(events.contains(.mintingCredentials(sessionName: "s", accountId: "123456789012", roleName: "r")))
        #expect(events.contains(.mintedCredentials(sessionName: "s", accountId: "123456789012", roleName: "r")))
        let mIdx = events.firstIndex(of: .mintingCredentials(sessionName: "s", accountId: "123456789012", roleName: "r"))
        let dIdx = events.firstIndex(of: .mintedCredentials(sessionName: "s", accountId: "123456789012", roleName: "r"))
        #expect(mIdx != nil && dIdx != nil && mIdx! < dIdx!)
        #expect(!events.contains(.mintCredentialsFailed(sessionName: "s", accountId: "123456789012", roleName: "r")))
        #expect(!events.contains(.roleAccessDenied(sessionName: "s", accountId: "123456789012", roleName: "r")))
    }

    // MARK: - Terminal failures → roleAccessDenied (both AWS error shapes)

    @Test("ForbiddenException (.roleNotAssigned) emits .mintingCredentials then .roleAccessDenied")
    func forbiddenEmitsRoleAccessDenied() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let portal = StubPortalRequesting()
        try await seedFreshToken(keychain: keychain)
        await portal.setNextGetRoleCredentialsResult(.failure(IAMIdentityCenterError.roleNotAssigned))
        let service = makeService(keychain: keychain, portal: portal)

        let (collector, collectTask) = collectMintEvents(from: service) {
            if case .roleAccessDenied = $0 { return true }
            return false
        }

        _ = try? await service.liveCredentials(forSession: "s", accountId: "123456789012", roleName: "r", region: "us-east-1")
        await collectTask.value

        let events = await collector.events
        #expect(events.contains(.mintingCredentials(sessionName: "s", accountId: "123456789012", roleName: "r")))
        #expect(events.contains(.roleAccessDenied(sessionName: "s", accountId: "123456789012", roleName: "r")))
        #expect(!events.contains(.mintedCredentials(sessionName: "s", accountId: "123456789012", roleName: "r")))
    }

    @Test("ResourceNotFoundException (.accountNotFound) also emits .roleAccessDenied")
    func resourceNotFoundEmitsRoleAccessDenied() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let portal = StubPortalRequesting()
        try await seedFreshToken(keychain: keychain)
        await portal.setNextGetRoleCredentialsResult(.failure(IAMIdentityCenterError.accountNotFound))
        let service = makeService(keychain: keychain, portal: portal)

        let (collector, collectTask) = collectMintEvents(from: service) {
            if case .roleAccessDenied = $0 { return true }
            return false
        }

        _ = try? await service.liveCredentials(forSession: "s", accountId: "123456789012", roleName: "r", region: "us-east-1")
        await collectTask.value

        let events = await collector.events
        #expect(events.contains(.roleAccessDenied(sessionName: "s", accountId: "123456789012", roleName: "r")))
        #expect(!events.contains(.mintCredentialsFailed(sessionName: "s", accountId: "123456789012", roleName: "r")))
    }

    // MARK: - Transient failure → mintCredentialsFailed

    @Test("Transient network failure emits .mintingCredentials then .mintCredentialsFailed")
    func transientEmitsMintCredentialsFailed() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let portal = StubPortalRequesting()
        try await seedFreshToken(keychain: keychain)
        await portal.setNextGetRoleCredentialsResult(.failure(IAMIdentityCenterError.network(URLError(.notConnectedToInternet))))
        let service = makeService(keychain: keychain, portal: portal)

        let (collector, collectTask) = collectMintEvents(from: service) {
            if case .mintCredentialsFailed = $0 { return true }
            return false
        }

        _ = try? await service.liveCredentials(forSession: "s", accountId: "123456789012", roleName: "r", region: "us-east-1")
        await collectTask.value

        let events = await collector.events
        #expect(events.contains(.mintingCredentials(sessionName: "s", accountId: "123456789012", roleName: "r")))
        #expect(events.contains(.mintCredentialsFailed(sessionName: "s", accountId: "123456789012", roleName: "r")))
        #expect(!events.contains(.roleAccessDenied(sessionName: "s", accountId: "123456789012", roleName: "r")))
        #expect(!events.contains(.mintedCredentials(sessionName: "s", accountId: "123456789012", roleName: "r")))
    }

    // MARK: - No bearer → NO mint events at all

    @Test("liveToken bearer failure (.notSignedIn) emits NO mint events")
    func noBearerEmitsNoMintEvents() async throws {
        defer { StubURLProtocol.reset() }
        // Empty keychain → liveToken throws .notSignedIn before any mint attempt.
        let portal = StubPortalRequesting()
        let service = makeService(portal: portal)

        let collector = EventCollector()
        let collectTask = Task {
            for await event in service.events { await collector.append(event) }
        }

        do {
            _ = try await service.liveCredentials(forSession: "s", accountId: "123456789012", roleName: "r", region: "us-east-1")
            Issue.record("Expected .notSignedIn to be thrown")
        } catch IAMIdentityCenterError.notSignedIn {
            // expected
        }
        // Let any stray event delivery settle, then stop collecting.
        await Task.yield()
        collectTask.cancel()
        _ = await collectTask.value

        let events = await collector.events
        let mintEvents = events.filter {
            switch $0 {
            case .mintingCredentials, .mintedCredentials, .mintCredentialsFailed, .roleAccessDenied:
                return true
            default:
                return false
            }
        }
        #expect(mintEvents.isEmpty, "No mint attempt was made — no mint events should fire. Got: \(mintEvents)")
        let portalCalls = await portal.getRoleCredentialsCallCount
        #expect(portalCalls == 0)
    }

    // MARK: - Coalesced callers do not double-emit .mintingCredentials

    @Test("Concurrent liveCredentials for the same tuple emit .mintingCredentials exactly once")
    func coalescedCallersEmitMintingOnce() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let portal = StubPortalRequesting()
        try await seedFreshToken(keychain: keychain)

        // Gate the mint so both callers are in-flight before it completes (D26 coalescing).
        // Capture the continuation so the test can release the gate once both callers have
        // coalesced; finishing the stream lets the `for await` fall through to the return.
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        await portal.setGetRoleCredentialsBlock {
            for await _ in gate { break }
            return makeDefaultMintedCredential()
        }
        let service = makeService(keychain: keychain, portal: portal)

        let (collector, collectTask) = collectMintEvents(from: service) {
            if case .mintedCredentials = $0 { return true }
            return false
        }

        async let c1 = service.liveCredentials(forSession: "s", accountId: "123456789012", roleName: "r", region: "us-east-1")
        async let c2 = service.liveCredentials(forSession: "s", accountId: "123456789012", roleName: "r", region: "us-east-1")
        // Let both callers reach the coalesce point (one registers inFlightMint, the other
        // awaits it), then release the gated mint so it can complete.
        try await Task.sleep(for: .milliseconds(50))
        gateContinuation.finish()
        _ = try await (c1, c2)
        await collectTask.value

        let events = await collector.events
        let mintingCount = events.filter {
            $0 == .mintingCredentials(sessionName: "s", accountId: "123456789012", roleName: "r")
        }.count
        #expect(mintingCount == 1, "Coalesced callers must not double-emit .mintingCredentials; got \(mintingCount)")
        let portalCalls = await portal.getRoleCredentialsCallCount
        #expect(portalCalls == 1)
    }

    // MARK: - Timer (handleMint) path emits the same events as the inline path

    @Test("T_mint/handleMint timer path emits .mintingCredentials then .mintedCredentials")
    func timerPathEmitsSameEvents() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let portal = StubPortalRequesting()
        try await seedFreshToken(keychain: keychain)
        await portal.setNextGetRoleCredentialsResult(.success(makeDefaultMintedCredential()))
        let service = makeService(keychain: keychain, portal: portal)

        let (collector, collectTask) = collectMintEvents(from: service) {
            if case .mintedCredentials = $0 { return true }
            return false
        }

        // expiresAt already inside the skew window → scheduleMint fires handleMint immediately,
        // which routes through the shared runMintBody (no duplicated emission).
        await service.scheduleMint(
            forSession: "s",
            accountId: "123456789012",
            roleName: "r",
            region: "us-east-1",
            expiresAt: Date().addingTimeInterval(60)
        )
        await collectTask.value

        let events = await collector.events
        #expect(events.contains(.mintingCredentials(sessionName: "s", accountId: "123456789012", roleName: "r")))
        #expect(events.contains(.mintedCredentials(sessionName: "s", accountId: "123456789012", roleName: "r")))
    }
}
}
