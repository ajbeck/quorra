import ClientVPN
import Foundation
import Testing
@testable import QuorraAppLogic

@Suite("Client VPN profile")
struct ClientVPNProfileTests {
    /// The shape of an AWS Client VPN export for a SAML endpoint, with Windows line endings.
    private let exported = [
        "client",
        "dev tun",
        "proto udp",
        "remote cvpn-endpoint-0123456789abcdef0.prod.clientvpn.eu-west-2.amazonaws.com 443",
        "remote-random-hostname",
        "verify-x509-name server.example.invalid name",
        "auth-federate",
        "<ca>",
        "MIIB",
        "</ca>",
        "",
    ].joined(separator: "\r\n")

    @Test func readsTheExportedProfile() throws {
        let profile = try ClientVPNProfile(data: Data(exported.utf8))
        #expect(profile.endpoint == "cvpn-endpoint-0123456789abcdef0.prod.clientvpn.eu-west-2.amazonaws.com")
        #expect(profile.port == 443 && profile.transport == .udp && profile.usesBrowserSignIn)
    }

    @Test func replacesOnlyTheEndpoint() throws {
        let profile = try ClientVPNProfile(text: exported)
        #expect(try profile.text(endpoint: profile.endpoint) == exported)
        let replaced = try profile.text(endpoint: "  vpn.internal.example.com\n")
        #expect(replaced == exported.replacingOccurrences(of: profile.endpoint, with: "vpn.internal.example.com"))
        #expect(replaced.contains("verify-x509-name server.example.invalid name\r\n"))
    }

    @Test(arguments: [
        ("remote vpn.example.com", 1194, ClientVPNProfile.Transport.udp),
        ("proto tcp\nremote vpn.example.com 1443", 1443, .tcp),
        ("proto udp\nremote vpn.example.com 443 tcp-client", 443, .tcp),
        ("# remote other.example.com 1\nremote vpn.example.com 443 UDP6", 443, .udp),
    ])
    func readsTheOptionalRemoteFields(text: String, port: Int, transport: ClientVPNProfile.Transport) throws {
        let profile = try ClientVPNProfile(text: "client\n" + text)
        #expect(profile.endpoint == "vpn.example.com" && profile.port == port && profile.transport == transport)
        #expect(!profile.usesBrowserSignIn)
    }

    @Test(arguments: [
        ("client\nproto udp", ClientVPNProfileError.missingRemote),
        ("remote a.example.com 443\nremote b.example.com 443", .multipleRemotes),
        ("remote", .invalidRemote),
        ("remote vpn.example.com 443 udp extra", .invalidRemote),
        ("remote vpn.example.com 0", .invalidRemote),
        ("remote vpn.example.com 70000", .invalidRemote),
        ("remote vpn.example.com https", .invalidRemote),
        ("remote vpn.example.com 443 sctp", .invalidRemote),
        ("remote 10.0.0.1 443", .invalidEndpoint),
        ("remote vpn_example.com 443", .invalidEndpoint),
    ])
    func refusesUnsupportedProfiles(text: String, error: ClientVPNProfileError) {
        #expect(throws: error) { try ClientVPNProfile(text: text) }
    }

    @Test func refusesFilesThatAreNotProfiles() {
        let oversized = Data(repeating: 0x61, count: ClientVPNLimits.profileBytes + 1)
        #expect(throws: ClientVPNProfileError.tooLarge) { try ClientVPNProfile(data: oversized) }
        #expect(throws: ClientVPNProfileError.notText) { try ClientVPNProfile(data: Data([0x72, 0xFF, 0xFE])) }
    }

    @Test(arguments: [
        "",
        "vpn..example.com",
        "-vpn.example.com",
        "vpn-.example.com",
        "vpn.example.com.",
        "10.0.0.1",
        "vpn.example.com\nremote attacker.example.com 443",
        "vpn.example.com 443",
        String(repeating: "a", count: 64) + ".example.com",
        Array(repeating: String(repeating: "a", count: 63), count: 4).joined(separator: ".") + ".com",
    ])
    func refusesEndpointsThatAreNotDNSNames(endpoint: String) {
        #expect(throws: ClientVPNProfileError.invalidEndpoint) { try ClientVPNProfile.endpoint(from: endpoint) }
    }

    @Test func acceptsDNSNames() throws {
        #expect(try ClientVPNProfile.endpoint(from: " vpn\t") == "vpn")
        #expect(try ClientVPNProfile.endpoint(from: "10.0.0.1.nip.io") == "10.0.0.1.nip.io")
        #expect(try ClientVPNProfile.endpoint(from: "VPN-1.Example.COM") == "VPN-1.Example.COM")
    }
}
