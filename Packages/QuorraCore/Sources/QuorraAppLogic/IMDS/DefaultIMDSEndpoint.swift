import Foundation
import SwiftData

/// The reserved, app-managed endpoint whose served profile can be changed without
/// changing the address used by local tools.
public enum DefaultIMDSEndpoint {
    public static let stableID = UUID(uuidString: "00000000-0000-0000-0000-000000007114")!
    public static let stableIDString = stableID.uuidString
    public static let name = "Default IMDS Endpoint"
    public static let bindAddress = "169.254.169.254"
    public static let port = 80
    public static let backendBindAddress = "127.0.0.1"
    public static let backendPort = 7_114
    public static let allowsIMDSv1 = false

    public static func matches(endpointID: String) -> Bool {
        endpointID.caseInsensitiveCompare(stableIDString) == .orderedSame
    }

    public static func matches(_ definition: IMDSEndpointDefinition) -> Bool {
        matches(endpointID: definition.stableIDString)
    }

    /// Creates the reserved definition once and repairs its fixed fields on later launches.
    /// The selected profile remains untouched while it is still available.
    @MainActor
    public static func ensureDefinition(
        in context: ModelContext,
        availableProfileNames: [String]
    ) throws -> IMDSEndpointDefinition {
        let endpointID = stableIDString
        let descriptor = FetchDescriptor<IMDSEndpointDefinition>(
            predicate: #Predicate { $0.stableIDString == endpointID }
        )

        if let definition = try context.fetch(descriptor).first {
            var changed = false
            if definition.name != name {
                definition.name = name
                changed = true
            }
            if definition.bindAddress != bindAddress {
                definition.bindAddress = bindAddress
                changed = true
            }
            if definition.port != port {
                definition.port = port
                changed = true
            }
            if definition.allowsIMDSv1 != allowsIMDSv1 {
                definition.allowsIMDSv1 = allowsIMDSv1
                changed = true
            }
            if !availableProfileNames.contains(definition.profileName),
               let firstProfileName = availableProfileNames.first {
                definition.profileName = firstProfileName
                changed = true
            }
            if changed {
                definition.updatedAt = .now
                try context.save()
            }
            return definition
        }

        let definition = IMDSEndpointDefinition(
            id: stableID,
            name: name,
            profileName: availableProfileNames.first ?? "",
            port: port,
            bindAddress: bindAddress,
            allowsIMDSv1: allowsIMDSv1
        )
        context.insert(definition)
        try context.save()
        return definition
    }
}
