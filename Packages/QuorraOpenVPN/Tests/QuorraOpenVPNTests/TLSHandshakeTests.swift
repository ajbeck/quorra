import QuorraOpenVPNTestSupport
import Foundation
import Testing

struct TLSHandshakeTests {
    private func fixture(_ name: String, extension suffix: String = "pem") throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: suffix, subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func productionVerifierAcceptsTrustedIdentityAndRejectsWrongIdentityOrChain() throws {
        let root = try fixture("tls-root"), server = try fixture("tls-server"), key = try fixture("tls-server", extension: "key")
        let profile = "client\ndev tun\nproto udp\nremote vpn.example.invalid 443\nauth-user-pass\nremote-cert-tls server\nverify-x509-name vpn.example.invalid name\n<ca>\n\(root)</ca>\n"
        #expect(QVPNTestTLSHandshake(profile, server, key))
        #expect(!QVPNTestTLSHandshake(profile.replacingOccurrences(of: "verify-x509-name vpn.example.invalid", with: "verify-x509-name wrong.example.invalid"), server, key))
        #expect(!QVPNTestTLSHandshake(try Fixtures.profile(), server, key))
    }
}
