import QuorraOpenVPNNative
import Foundation

/// Public Swift boundary; raw C++ types and logs never reach the provider.
public enum VPNCore {
    public static func selfTest() -> Bool {
        QVPNCore.selfTest() && Bundle.module.url(forResource: "README", withExtension: "md", subdirectory: "Resources/Source") != nil
    }

    public static func validate(profile: String) throws {
        try QVPNCore.evaluateProfile(profile)
    }

    public static func authenticationChallenge(_ data: Data) -> VPNAuthenticationChallenge? {
        guard let challenge = QVPNCore.parseChallenge(data) else { return nil }
        return VPNAuthenticationChallenge(url: challenge.url, cookie: challenge.cookie)
    }
}

public struct VPNAuthenticationChallenge: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let url: URL
    public let cookie: Data
    public var description: String { "VPN authentication challenge (redacted)" }
    public var debugDescription: String { description }
}
