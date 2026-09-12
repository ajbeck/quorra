import Foundation
import Testing
@testable import QuorraIMDSHelperCore

@Suite("Interface alias ownership")
struct InterfaceAliasManagerTests {
    @Test func enableCreatesAliasBeforeRecordingOwnership() throws {
        let system = StubInterfaceAliasSystem()
        let manager = makeManager(system: system)

        #expect(try manager.enable() == .created)
        #expect(system.operations == [
            .inspectAddress,
            .addAlias,
            .createMarker,
        ])
    }

    @Test func enableReclaimsAnOwnedAliasAfterDaemonRestart() throws {
        let system = StubInterfaceAliasSystem(
            configuredInterface: "lo0",
            markerExists: true
        )
        let manager = makeManager(system: system)

        #expect(try manager.enable() == .reclaimed)
        #expect(system.operations == [.inspectAddress])
    }

    @Test func enableRefusesAnUnownedAlias() throws {
        let system = StubInterfaceAliasSystem(configuredInterface: "lo0")
        let manager = makeManager(system: system)

        #expect(throws: InterfaceAliasManagerError.addressConflict(interfaceName: "lo0")) {
            try manager.enable()
        }
        #expect(system.operations == [.inspectAddress])
    }

    @Test func enableRefusesOwnedAddressOnAnotherInterface() throws {
        let system = StubInterfaceAliasSystem(
            configuredInterface: "utun4",
            markerExists: true
        )
        let manager = makeManager(system: system)

        #expect(throws: InterfaceAliasManagerError.ownershipConflict(interfaceName: "utun4")) {
            try manager.enable()
        }
        #expect(system.operations == [.inspectAddress])
    }

    @Test func enableRepairsStaleMarkerBeforeCreatingAlias() throws {
        let system = StubInterfaceAliasSystem(markerExists: true)
        let manager = makeManager(system: system)

        #expect(try manager.enable() == .created)
        #expect(system.operations == [
            .inspectAddress,
            .removeMarker,
            .addAlias,
            .createMarker,
        ])
    }

    @Test func markerFailureRollsBackNewAlias() {
        let system = StubInterfaceAliasSystem(createMarkerError: StubError.markerCreation)
        let manager = makeManager(system: system)

        #expect(throws: StubError.markerCreation) {
            try manager.enable()
        }
        #expect(system.operations == [
            .inspectAddress,
            .addAlias,
            .createMarker,
            .removeAlias,
        ])
    }

    @Test func disableRemovesOnlyAnOwnedAlias() throws {
        let system = StubInterfaceAliasSystem(
            configuredInterface: "lo0",
            markerExists: true
        )
        let manager = makeManager(system: system)

        #expect(try manager.disable() == .aliasRemoved)
        #expect(system.operations == [
            .inspectAddress,
            .removeAlias,
            .removeMarker,
        ])
    }

    @Test func disableLeavesUnownedAddressUntouched() throws {
        let system = StubInterfaceAliasSystem(configuredInterface: "lo0")
        let manager = makeManager(system: system)

        #expect(try manager.disable() == .notOwned)
        #expect(system.operations.isEmpty)
    }

    private func makeManager(system: StubInterfaceAliasSystem) -> InterfaceAliasManager {
        InterfaceAliasManager(
            system: system,
            ownershipMarkerURL: URL(filePath: "/test/alias-marker")
        )
    }
}

private enum StubError: Error {
    case markerCreation
}

private final class StubInterfaceAliasSystem: InterfaceAliasSystem {
    enum Operation: Equatable {
        case inspectAddress
        case addAlias
        case removeAlias
        case createMarker
        case removeMarker
    }

    private var configuredInterface: String?
    private var markerExists: Bool
    private let createMarkerError: Error?
    private(set) var operations: [Operation] = []

    init(
        configuredInterface: String? = nil,
        markerExists: Bool = false,
        createMarkerError: Error? = nil
    ) {
        self.configuredInterface = configuredInterface
        self.markerExists = markerExists
        self.createMarkerError = createMarkerError
    }

    func interfaceName(containingIPv4Address address: String) throws -> String? {
        operations.append(.inspectAddress)
        return configuredInterface
    }

    func addIPv4Alias(address: String, prefixLength: Int, to interfaceName: String) throws {
        operations.append(.addAlias)
        configuredInterface = interfaceName
    }

    func removeIPv4Alias(address: String, from interfaceName: String) throws {
        operations.append(.removeAlias)
        configuredInterface = nil
    }

    func hasOwnershipMarker(at url: URL) throws -> Bool {
        markerExists
    }

    func createOwnershipMarker(at url: URL) throws {
        operations.append(.createMarker)
        if let createMarkerError {
            throw createMarkerError
        }
        markerExists = true
    }

    func removeOwnershipMarker(at url: URL) throws {
        operations.append(.removeMarker)
        markerExists = false
    }
}
