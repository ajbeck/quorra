import QuorraOpenVPNNative
import Foundation
import NetworkExtension
import Testing
@testable import QuorraOpenVPN

enum Fixtures {
    static func certificate(_ name: String = "strong") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "der", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func profile() throws -> String {
        let pem = try certificate().base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return """
        client
        dev tun
        proto udp
        remote vpn.example.invalid 443
        auth-user-pass
        auth-federate
        remote-cert-tls server
        verify-x509-name vpn.example.invalid name
        <ca>
        -----BEGIN CERTIFICATE-----
        \(pem)
        -----END CERTIFICATE-----
        </ca>
        """
    }

    static let pushed = "topology subnet\nifconfig 10.23.0.8 255.255.255.0\nroute 10.24.0.0 255.255.0.0\n"
    static let cookie = Data("CRV1:R:synthetic-state:b'dXNlcg==':https://signin.example.invalid/?state=synthetic".utf8)

    static func packet(length: Int = 100, ipv6: Bool = false) -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        bytes[0] = ipv6 ? 0x60 : 0x45
        let size = ipv6 ? length - 40 : length
        bytes[ipv6 ? 4 : 2] = UInt8(size >> 8)
        bytes[ipv6 ? 5 : 3] = UInt8(size & 255)
        return Data(bytes)
    }
}

struct CoreTests {
    @Test func packagedCryptoPassesKnownAnswerTests() {
        #expect(QVPNCore.selfTest())
        #expect(VPNCore.selfTest())
    }

    @Test func explicitProfileAndInlineTrustAreAccepted() throws {
        try VPNCore.validate(profile: Fixtures.profile())
        try VPNCore.validate(profile: Fixtures.profile() + "\ntls-version-min 1.3")
    }

    @Test(arguments: ["", "client\ndev tun", String(repeating: "x", count: 65537)])
    func malformedOrOversizedProfilesAreRejected(profile: String) {
        #expect(throws: (any Error).self) { try VPNCore.validate(profile: profile) }
    }

    @Test(arguments: ["up /tmp/script", "remote-random-hostname", "script-security 2", "http-proxy proxy.example.invalid 80", "peer-fingerprint 00", "ca /tmp/ca.pem", "remote second.example.invalid 443", "auth-user-pass /tmp/credentials", "tls-version-min 1.0", "unknown-option", "\0"])
    func executableExternalAndAmbiguousOptionsAreRejected(option: String) throws {
        let profile = try Fixtures.profile() + "\n" + option
        #expect(throws: (any Error).self) { try VPNCore.validate(profile: profile) }
    }

    @Test func awsWrappedChallengePreservesOpaqueStateAndRedactsDescriptions() throws {
        let challenge = try #require(VPNCore.authenticationChallenge(Fixtures.cookie))
        #expect(challenge.cookie == Fixtures.cookie)
        #expect(challenge.url.host == "signin.example.invalid")
        #expect(!String(describing: challenge).contains("synthetic-state"))
        #expect(!String(reflecting: challenge).contains("synthetic"))
    }

    @Test(arguments: ["http://signin.example.invalid", "https://user:secret@signin.example.invalid", "https://signin.example.invalid/#secret", "https://", "javascript:alert(1)"])
    func unsafeChallengeURLsAreRejected(url: String) {
        #expect(VPNCore.authenticationChallenge(Data("CRV1:R:synthetic:dXNlcg==:\(url)".utf8)) == nil)
    }

    @Test func credentialsAreBoundedAndDoNotExposeTokens() throws {
        let credentials = try #require(QVPNCredentials.cachedUsername(Data("user".utf8), token: Data("synthetic-token".utf8)))
        #expect(!credentials.description.contains("synthetic"))
        #expect(QVPNCredentials.cachedUsername(Data(), token: Data([1])) == nil)
        #expect(QVPNCredentials.cachedUsername(Data([1]), token: Data([0])) == nil)
        #expect(QVPNCredentials.cachedUsername(Data([1]), token: Data(repeating: 1, count: 120 * 1024)) == nil)
        #expect(QVPNCredentials.challenge(Fixtures.cookie, response: Data(repeating: 65, count: 70_000)) != nil)
        #expect(QVPNCredentials.challenge(Fixtures.cookie, response: Data(repeating: 65, count: 128 * 1024)) == nil)
        #expect(QVPNCredentials.challenge(Data("invalid".utf8), response: Data([1])) == nil)
    }

    @Test func certificatePolicyRejectsWeakKeysWeakSignaturesAndMalformedDER() throws {
        #expect(try QVPNCore.acceptsCertificateStrength(Fixtures.certificate()))
        #expect(try !QVPNCore.acceptsCertificateStrength(Fixtures.certificate("weak-key")))
        #expect(try !QVPNCore.acceptsCertificateStrength(Fixtures.certificate("weak-signature")))
        #expect(!QVPNCore.acceptsCertificateStrength(Data()))
        #expect(try !QVPNCore.acceptsCertificateStrength(Fixtures.certificate() + Data([0])))
    }

    @Test func packetValidationEnforcesFamilyLengthAndNegotiatedMTU() {
        #expect(QVPNCore.packetProtocolFamily(Fixtures.packet(), maximumTransmissionUnit: 1500) == AF_INET)
        #expect(QVPNCore.packetProtocolFamily(Fixtures.packet(ipv6: true), maximumTransmissionUnit: 1500) == AF_INET6)
        #expect(QVPNCore.packetProtocolFamily(Fixtures.packet(length: 1500), maximumTransmissionUnit: 1500) == AF_INET)
        #expect(QVPNCore.packetProtocolFamily(Fixtures.packet(length: 1500), maximumTransmissionUnit: 1400) == 0)
        #expect(QVPNCore.packetProtocolFamily(Fixtures.packet(), maximumTransmissionUnit: 0) == 0)
        #expect(QVPNCore.packetProtocolFamily(Fixtures.packet().dropLast(), maximumTransmissionUnit: 1500) == 0)
        #expect(QVPNCore.packetProtocolFamily(Data(repeating: 0, count: 100), maximumTransmissionUnit: 1500) == 0)
    }
}

struct NetworkSettingsTests {
    private func settings(_ extra: String = "") throws -> NEPacketTunnelNetworkSettings {
        try QVPNCore.networkSettings(forPushedOptions: Fixtures.pushed + extra, remoteAddress: "192.0.2.8")
    }

    @Test func splitRoutesDNSAndEndpointExclusionAreMapped() throws {
        let network = try settings("dhcp-option DNS 10.24.0.2\ndhcp-option DOMAIN corp.example.invalid\n")
        #expect(network.ipv4Settings?.addresses == ["10.23.0.8"])
        #expect(network.ipv4Settings?.includedRoutes?.contains { $0.destinationAddress == "10.24.0.0" } == true)
        #expect(network.ipv4Settings?.excludedRoutes?.contains { $0.destinationAddress == "192.0.2.8" && $0.destinationSubnetMask == "255.255.255.255" } == true)
        #expect(network.dnsSettings?.servers == ["10.24.0.2"])
        #expect(network.dnsSettings?.matchDomainsNoSearch == true)
        #expect(network.mtu == 1500)
    }

    @Test func absentDNSDoesNotInstallFallbackResolver() throws {
        #expect(try settings().dnsSettings == nil)
    }

    @Test(arguments: ["redirect-gateway def1\n", "route 0.0.0.0 0.0.0.0\n", "dhcp-option DNS 192.0.2.53\n", "dhcp-option DNS 192.0.2.8\n", "tun-mtu 9000\n", "route-ipv6 2001:db8:24::/64\n"])
    func unsupportedOrLeakingSettingsAreRejected(options: String) {
        #expect(throws: (any Error).self) { try settings(options) }
    }
}
