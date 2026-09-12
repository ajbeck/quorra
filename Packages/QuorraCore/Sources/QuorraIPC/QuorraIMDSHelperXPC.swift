import Foundation

public enum QuorraIMDSHelperXPC {
    public static let machServiceName = "dev.ajbeck.quorra.imds-helper"
    public static let helperIdentifier = "dev.ajbeck.quorra.imds-helper"

    public static let appCodeSigningRequirement = codeSigningRequirement(
        identifier: QuorraIPCProtocol.appIdentifier
    )
    public static let helperCodeSigningRequirement = codeSigningRequirement(
        identifier: helperIdentifier
    )

    public static func makePrivilegedConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: QuorraIMDSHelperXPCProtocol.self
        )
        connection.setCodeSigningRequirement(helperCodeSigningRequirement)
        return connection
    }

    private static func codeSigningRequirement(identifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" "
            + "and certificate leaf[subject.OU] = \"\(QuorraIPCProtocol.teamIdentifier)\""
    }
}

public enum QuorraIMDSHelperState: String, Codable, CaseIterable, Sendable {
    case disabled
    case enabling
    case enabled
    case disabling
    case failed
}

@objc(QuorraIMDSHelperXPCProtocol)
public protocol QuorraIMDSHelperXPCProtocol: AnyObject {
    func status(reply: @escaping (String, String?) -> Void)
    func enable(reply: @escaping (String, String?) -> Void)
    func disable(reply: @escaping (String, String?) -> Void)
}
