import Foundation
import Testing
@testable import DatabaseProxy

struct MySQLProtocolTests {
    @Test func parsesGreetingAndRejectsTruncationAndLegacyProtocol() throws {
        let nonce = Data(1...20)
        let bytes = MySQLWire.greeting(nonce: nonce, connectionID: 42)
        let greeting = try MySQLWire.Greeting(bytes)
        #expect(greeting.nonce == nonce)
        #expect(greeting.plugin == "caching_sha2_password")
        for length in 0..<bytes.count {
            #expect(throws: (any Error).self) { try MySQLWire.Greeting(Data(bytes.prefix(length))) }
        }
        var old = bytes; old[0] = 9
        #expect(throws: ProxyError.unsupportedMySQLProtocol) { try MySQLWire.Greeting(old) }
    }

    @Test func lengthEncodedPayloadsAreBoundedAndRejectNullOrInvalidLength() throws {
        for count in [0, 1, 250, 251, 65535, 65536] {
            let payload = Data(repeating: 7, count: count)
            var cursor = MySQLWire.Cursor(MySQLWire.lengthEncoded(payload))
            #expect(try cursor.lengthEncoded() == payload)
            #expect(cursor.remaining == 0)
        }
        for data in [Data([251]), Data([255]), Data([254]) + Data(repeating: 255, count: 8), Data([252, 4])] {
            var cursor = MySQLWire.Cursor(data)
            #expect(throws: ProxyError.malformedMySQLMessage) { try cursor.lengthEncoded() }
        }
    }

    @Test func localHandshakeNegotiatesIntersectionOfClientAndServerCapabilities() throws {
        // Captured capability flags from a current libmysqlclient handshake.
        for flags: UInt32 in [0x19bfa28d, MySQLWire.capabilities | 0x20 | 0x2000000] {
            var payload = MySQLWire.header(capabilities: flags, characterSet: 45)
            payload += Data("quorra\0".utf8) + MySQLWire.lengthEncoded(Data(repeating: 1, count: 32))
            payload += Data("example\0caching_sha2_password\0".utf8) + MySQLWire.lengthEncoded(Data())
            let handshake = try MySQLWire.ClientHandshake(payload)
            #expect(handshake.capabilities == flags & MySQLWire.capabilities)
            #expect(handshake.username == "quorra")
            #expect(handshake.database == "example")
        }
    }

    @Test func localHandshakeRejectsSSLRequest() {
        #expect(throws: ProxyError.unsupportedMySQLProtocol) {
            try MySQLWire.ClientHandshake(MySQLWire.header(capabilities: MySQLWire.capabilities | MySQLWire.ssl, characterSet: 45))
        }
    }

    @Test func IAMNeverSendsTokenOutsideVerifiedTLSOrUnderWrongPlugin() throws {
        let nonce = Data(1...20)
        #expect(throws: ConfigurationError.iamRequiresTLS) {
            try MySQLAuthentication.response(plugin: "mysql_clear_password", password: "synthetic-token", nonce: nonce, verifiedTLS: false, iam: true)
        }
        #expect(try MySQLAuthentication.response(plugin: "caching_sha2_password", password: "synthetic-token", nonce: nonce, verifiedTLS: true, iam: true).isEmpty)
        #expect(try MySQLAuthentication.response(plugin: "mysql_clear_password", password: "synthetic-token", nonce: nonce, verifiedTLS: true, iam: true) == Data("synthetic-token\0".utf8))
        #expect(throws: ProxyError.mysqlAuthenticationRequiresTLS) {
            try MySQLAuthentication.response(plugin: "sha256_password", password: "synthetic", nonce: nonce, verifiedTLS: false, iam: false)
        }
    }
}
