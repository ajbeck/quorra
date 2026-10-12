import CryptoKit
import Foundation

nonisolated enum MySQLAuthentication {
    static func response(plugin: String, password: String, nonce: Data, verifiedTLS: Bool, iam: Bool) throws -> Data {
        guard !password.contains("\0"), nonce.count == 20 else { throw ProxyError.malformedMySQLMessage }
        if iam {
            guard verifiedTLS else { throw ConfigurationError.iamRequiresTLS }
            // RDS initially advertises its default plugin then switches IAM
            // users to mysql_clear_password. Do not send token-derived proofs.
            return plugin == "mysql_clear_password" ? Data(password.utf8) + Data([0]) : Data()
        }
        if password.isEmpty { return Data() }
        let bytes = Data(password.utf8)
        switch plugin {
        case "mysql_native_password":
            let first = Data(Insecure.SHA1.hash(data: bytes))
            let second = Data(Insecure.SHA1.hash(data: first))
            return Data(zip(first, Insecure.SHA1.hash(data: nonce + second)).map { $0 ^ $1 })
        case "caching_sha2_password":
            let first = Data(SHA256.hash(data: bytes))
            let second = Data(SHA256.hash(data: first))
            return Data(zip(first, SHA256.hash(data: second + nonce)).map { $0 ^ $1 })
        case "sha256_password", "mysql_clear_password":
            guard verifiedTLS else { throw ProxyError.mysqlAuthenticationRequiresTLS }
            return bytes + Data([0])
        default: throw ProxyError.unsupportedMySQLProtocol
        }
    }

    static func verifyLocal(_ handshake: MySQLWire.ClientHandshake, password: String, nonce: Data) throws {
        guard ["caching_sha2_password", "mysql_native_password"].contains(handshake.plugin) else {
            throw ProxyError.unsupportedMySQLProtocol
        }
        let expected = try response(plugin: handshake.plugin, password: password, nonce: nonce, verifiedTLS: false, iam: false)
        guard handshake.response.count == expected.count,
              zip(handshake.response, expected).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else {
            throw ProxyError.localAuthentication
        }
    }
}
