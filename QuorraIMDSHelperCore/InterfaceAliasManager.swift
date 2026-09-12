import Foundation

public protocol InterfaceAliasSystem {
    func interfaceName(containingIPv4Address address: String) throws -> String?
    func addIPv4Alias(address: String, prefixLength: Int, to interfaceName: String) throws
    func removeIPv4Alias(address: String, from interfaceName: String) throws
    func hasOwnershipMarker(at url: URL) throws -> Bool
    func createOwnershipMarker(at url: URL) throws
    func removeOwnershipMarker(at url: URL) throws
}

@MainActor
public protocol InterfaceAliasManaging {
    func enable() throws -> InterfaceAliasActivation
    func disable() throws -> InterfaceAliasDeactivation
}

public enum InterfaceAliasActivation: Equatable {
    case created
    case reclaimed
}

public enum InterfaceAliasDeactivation: Equatable {
    case notOwned
    case markerRemoved
    case aliasRemoved
}

public enum InterfaceAliasManagerError: LocalizedError, Equatable {
    case addressConflict(interfaceName: String)
    case ownershipConflict(interfaceName: String)
    case ownershipRollbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .addressConflict(let interfaceName):
            return "The metadata address is already configured on \(interfaceName)."
        case .ownershipConflict(let interfaceName):
            return "Quorra's ownership marker conflicts with an address configured on \(interfaceName)."
        case .ownershipRollbackFailed(let message):
            return "Quorra could not record or roll back metadata-address ownership: \(message)"
        }
    }
}

public struct InterfaceAliasManager {
    private let system: InterfaceAliasSystem
    private let interfaceName: String
    private let address: String
    private let prefixLength: Int
    private let ownershipMarkerURL: URL

    public init(
        system: InterfaceAliasSystem,
        interfaceName: String = IMDSNetworkConfiguration.interfaceName,
        address: String = IMDSNetworkConfiguration.publicAddress,
        prefixLength: Int = IMDSNetworkConfiguration.publicPrefixLength,
        ownershipMarkerURL: URL = IMDSNetworkConfiguration.ownershipMarkerURL
    ) {
        self.system = system
        self.interfaceName = interfaceName
        self.address = address
        self.prefixLength = prefixLength
        self.ownershipMarkerURL = ownershipMarkerURL
    }

    public func enable() throws -> InterfaceAliasActivation {
        let markerExists = try system.hasOwnershipMarker(at: ownershipMarkerURL)
        let configuredInterface = try system.interfaceName(containingIPv4Address: address)

        if markerExists {
            switch configuredInterface {
            case interfaceName:
                return .reclaimed
            case nil:
                try system.removeOwnershipMarker(at: ownershipMarkerURL)
            case .some(let conflictingInterface):
                throw InterfaceAliasManagerError.ownershipConflict(
                    interfaceName: conflictingInterface
                )
            }
        } else if let configuredInterface {
            throw InterfaceAliasManagerError.addressConflict(
                interfaceName: configuredInterface
            )
        }

        try system.addIPv4Alias(
            address: address,
            prefixLength: prefixLength,
            to: interfaceName
        )

        do {
            try system.createOwnershipMarker(at: ownershipMarkerURL)
        } catch {
            do {
                try system.removeIPv4Alias(address: address, from: interfaceName)
            } catch let rollbackError {
                throw InterfaceAliasManagerError.ownershipRollbackFailed(
                    "marker error: \(error.localizedDescription); rollback error: \(rollbackError.localizedDescription)"
                )
            }
            throw error
        }

        return .created
    }

    public func disable() throws -> InterfaceAliasDeactivation {
        guard try system.hasOwnershipMarker(at: ownershipMarkerURL) else {
            return .notOwned
        }

        switch try system.interfaceName(containingIPv4Address: address) {
        case interfaceName:
            try system.removeIPv4Alias(address: address, from: interfaceName)
            try system.removeOwnershipMarker(at: ownershipMarkerURL)
            return .aliasRemoved
        case nil:
            try system.removeOwnershipMarker(at: ownershipMarkerURL)
            return .markerRemoved
        case .some(let conflictingInterface):
            throw InterfaceAliasManagerError.ownershipConflict(
                interfaceName: conflictingInterface
            )
        }
    }
}

extension InterfaceAliasManager: InterfaceAliasManaging {}
