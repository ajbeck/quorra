import Foundation
import Testing
@testable import QuorraIMDSHelperCore

@Suite("IMDS helper service")
@MainActor
struct IMDSHelperServiceTests {
    @Test func enableProbesBackendThenAddsAliasThenStartsRelay() async throws {
        let fixture = ServiceFixture()

        try await fixture.service.enable()

        #expect(fixture.events.values == [.probe, .enableAlias, .startRelay])
        #expect(fixture.service.state == .enabled)
    }

    @Test func enableRequiresRootBeforeChangingSystemState() async {
        let fixture = ServiceFixture(isPrivileged: false)

        await #expect(throws: IMDSHelperServiceError.requiresRoot) {
            try await fixture.service.enable()
        }
        #expect(fixture.events.values.isEmpty)
    }

    @Test func backendFailureDoesNotAddAlias() async {
        let fixture = ServiceFixture(probeError: TestError.backend)

        await #expect(throws: TestError.backend) {
            try await fixture.service.enable()
        }
        #expect(fixture.events.values == [.probe])
        #expect(fixture.service.state == .failed(TestError.backend.localizedDescription))
    }

    @Test func relayFailureRollsBackOwnedAlias() async {
        let fixture = ServiceFixture(relayStartError: TestError.relay)

        await #expect(throws: TestError.relay) {
            try await fixture.service.enable()
        }
        #expect(fixture.events.values == [
            .probe,
            .enableAlias,
            .startRelay,
            .disableAlias,
        ])
    }

    @Test func rollbackFailurePreservesBothErrors() async {
        let fixture = ServiceFixture(
            relayStartError: TestError.relay,
            aliasDisableError: TestError.cleanup
        )

        await #expect(throws: IMDSHelperServiceError.self) {
            try await fixture.service.enable()
        }
        guard case .failed(let message) = fixture.service.state else {
            Issue.record("Expected a failed service state")
            return
        }
        #expect(message.contains(TestError.relay.localizedDescription))
        #expect(message.contains(TestError.cleanup.localizedDescription))
    }

    @Test func disableStopsRelayBeforeRemovingAlias() throws {
        let fixture = ServiceFixture()

        try fixture.service.disable()

        #expect(fixture.events.values == [.stopRelay, .disableAlias])
        #expect(fixture.service.state == .disabled)
    }

    @Test func repeatedEnableIsIdempotent() async throws {
        let fixture = ServiceFixture()

        try await fixture.service.enable()
        try await fixture.service.enable()

        #expect(fixture.events.values == [.probe, .enableAlias, .startRelay])
    }
}

@MainActor
private final class ServiceFixture {
    let events: EventLog
    let service: IMDSHelperService

    init(
        isPrivileged: Bool = true,
        probeError: Error? = nil,
        relayStartError: Error? = nil,
        aliasDisableError: Error? = nil
    ) {
        let events = EventLog()
        self.events = events
        service = IMDSHelperService(
            backendProbe: StubBackendProbe(events: events, error: probeError),
            aliasManager: StubAliasManager(
                events: events,
                disableError: aliasDisableError
            ),
            relay: StubRelay(events: events, startError: relayStartError),
            isPrivileged: { isPrivileged }
        )
    }
}

private enum ServiceEvent: Equatable {
    case probe
    case enableAlias
    case disableAlias
    case startRelay
    case stopRelay
}

@MainActor
private final class EventLog {
    var values: [ServiceEvent] = []
}

@MainActor
private struct StubBackendProbe: IMDSBackendProbing {
    let events: EventLog
    let error: Error?

    func probe() async throws {
        events.values.append(.probe)
        if let error { throw error }
    }
}

@MainActor
private final class StubAliasManager: InterfaceAliasManaging {
    let events: EventLog
    let disableError: Error?

    init(events: EventLog, disableError: Error?) {
        self.events = events
        self.disableError = disableError
    }

    func enable() throws -> InterfaceAliasActivation {
        events.values.append(.enableAlias)
        return .created
    }

    func disable() throws -> InterfaceAliasDeactivation {
        events.values.append(.disableAlias)
        if let disableError { throw disableError }
        return .aliasRemoved
    }
}

@MainActor
private final class StubRelay: IMDSTCPRelaying {
    let events: EventLog
    let startError: Error?

    init(events: EventLog, startError: Error?) {
        self.events = events
        self.startError = startError
    }

    func start() async throws {
        events.values.append(.startRelay)
        if let startError { throw startError }
    }

    func stop() {
        events.values.append(.stopRelay)
    }
}

private enum TestError: String, LocalizedError {
    case backend
    case relay
    case cleanup

    var errorDescription: String? { rawValue }
}
