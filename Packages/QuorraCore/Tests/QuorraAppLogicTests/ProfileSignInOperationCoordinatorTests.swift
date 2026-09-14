import Foundation
import IAMIdentityCenter
import QuorraIPC
import SwiftData
import Testing
@testable import QuorraAppLogic

@MainActor
@Suite("Profile sign-in operations")
struct ProfileSignInOperationCoordinatorTests {
    /// Held for the suite's lifetime: a context outlives nothing once its container is released.
    private let container: ModelContainer

    init() throws {
        container = try QuorraMetadataSchema.makeContainer(inMemory: true)
        let context = container.mainContext
        let session = SessionDefinition(name: "production", startURL: "https://example.awsapps.com/start", region: "us-east-1")
        context.insert(session)
        context.insert(ProfileDefinition(name: "production-admin", session: session, accountID: "111111111111", roleName: "AdministratorAccess", region: "us-east-1"))
        context.insert(ProfileDefinition(name: "static", session: nil, accountID: "", roleName: ""))
        try context.save()
    }

    @Test func operationMovesFromStartingToWaitingToSucceeded() async throws {
        let service = StubIdentityCenterService()
        await service.setVerificationToFire(Self.verification)
        await service.setHoldAfterVerification(true)
        await service.setSignInResult(.success(Self.token))
        let coordinator = makeCoordinator(service: service)

        let initial = try coordinator.begin(profileName: "production-admin")
        #expect(initial.state == .starting)

        await service.awaitVerificationFired()
        #expect(try coordinator.operation(id: initial.id).state == .waitingForUser)

        await service.releaseHold()
        let completed = try await terminalOperation(initial.id, coordinator: coordinator)
        #expect(completed.state == .succeeded)
        #expect(completed.profileName == "production-admin")
        #expect(completed.sessionName == "production")
        #expect(completed.message == nil)
    }

    @Test func failedSignInRetainsActionableError() async throws {
        let service = StubIdentityCenterService()
        await service.setSignInResult(.failure(.expiredDeviceCode))
        let coordinator = makeCoordinator(service: service)

        let initial = try coordinator.begin(profileName: "production-admin")
        let completed = try await terminalOperation(initial.id, coordinator: coordinator)

        #expect(completed.state == .failed)
        #expect(completed.message == IAMIdentityCenterError.expiredDeviceCode.localizedDescription)
    }

    @Test func cancellingStopsPollingStateAndForwardsToIdentityService() async throws {
        let service = StubIdentityCenterService()
        await service.setVerificationToFire(Self.verification)
        await service.setHoldAfterVerification(true)
        await service.setSignInResult(.success(Self.token))
        let coordinator = makeCoordinator(service: service)
        let initial = try coordinator.begin(profileName: "production-admin")
        await service.awaitVerificationFired()

        let cancelled = try await coordinator.cancel(id: initial.id)

        #expect(cancelled.state == .cancelled)
        #expect(await service.cancelCallCount == 1)
        await service.releaseHold()
        await Task.yield()
        #expect(try coordinator.operation(id: initial.id).state == .cancelled)
    }

    @Test func rejectsMissingAndNonIdentityCenterProfiles() throws {
        let service = StubIdentityCenterService()
        let coordinator = makeCoordinator(service: service)

        #expect(throws: ProfileSignInOperationError.profileNotFound("missing")) {
            try coordinator.begin(profileName: "missing")
        }
        #expect(throws: ProfileSignInOperationError.profileDoesNotUseIdentityCenter("static")) {
            try coordinator.begin(profileName: "static")
        }
    }

    private func makeCoordinator(
        service: StubIdentityCenterService
    ) -> ProfileSignInOperationCoordinator {
        ProfileSignInOperationCoordinator(modelContext: container.mainContext, credentialsModel: CredentialsModel(service: service))
    }

    private func terminalOperation(
        _ id: UUID,
        coordinator: ProfileSignInOperationCoordinator
    ) async throws -> QuorraProfileSignInOperationRecord {
        for _ in 0..<100 {
            let operation = try coordinator.operation(id: id)
            if operation.state.isTerminal { return operation }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Sign-in operation did not reach a terminal state")
        return try coordinator.operation(id: id)
    }

    private static let verification = DeviceVerification(
        userCode: "ABCD-1234",
        verificationUri: URL(string: "https://example.com/device")!,
        verificationUriComplete: URL(string: "https://example.com/device?code=ABCD-1234")!,
        expiresAt: Date().addingTimeInterval(300),
        interval: 5
    )

    private static let token = StoredSSOToken(
        accessToken: "token",
        expiresAt: Date().addingTimeInterval(3600),
        refreshToken: nil,
        issuedAt: Date(),
        region: "us-east-1",
        sessionName: "production"
    )
}
