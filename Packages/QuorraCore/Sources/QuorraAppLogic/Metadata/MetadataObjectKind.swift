import Foundation

public enum MetadataObjectKind: String, CaseIterable, Codable, Sendable {
    case session
    case profile
    case imdsEndpoint

    public var title: String {
        switch self {
        case .session:
            return "Sessions"
        case .profile:
            return "Profiles"
        case .imdsEndpoint:
            return "IMDS Endpoints"
        }
    }

    public var systemImage: String {
        switch self {
        case .session:
            return "cloud"
        case .profile:
            return "key"
        case .imdsEndpoint:
            return "antenna.radiowaves.left.and.right"
        }
    }
}
