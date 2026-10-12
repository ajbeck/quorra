import CryptoKit
import Foundation
import Security

nonisolated enum ProxyRandom {
    static func bytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw ProxyError.localAuthentication }
        return Data(bytes)
    }
}

/// SCRAM-SHA-256 without channel binding for the loopback-only TCP endpoint.
/// Generated local passwords are ASCII, so SASLprep leaves them unchanged.
nonisolated struct PostgreSQLSCRAM: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let serverFirst: String
    private let clientFirstBare: String
    private let channelBinding: String
    private let nonce: String
    private let storedKey: Data
    private let serverKey: Data
    var description: String { "PostgreSQLSCRAM(redacted)" }
    var debugDescription: String { description }

    init(password: String, clientFirst: String, salt: Data, serverNonce: String, iterations: Int = 4096) throws {
        guard (4096...100_000).contains(iterations), !salt.isEmpty,
              clientFirst.utf8.count <= 2048, clientFirst.hasPrefix("n,,") || clientFirst.hasPrefix("y,,") else {
            throw ProxyError.localAuthentication
        }
        channelBinding = Data(clientFirst.prefix(3).utf8).base64EncodedString()
        clientFirstBare = String(clientFirst.dropFirst(3))
        let attributes = clientFirstBare.split(separator: ",", omittingEmptySubsequences: false)
        guard attributes.count == 2, attributes[0].hasPrefix("n="), attributes[1].hasPrefix("r=") else {
            throw ProxyError.localAuthentication
        }
        let clientNonce = String(attributes[1].dropFirst(2))
        guard (16...512).contains(clientNonce.utf8.count), !serverNonce.isEmpty,
              (clientNonce + serverNonce).utf8.allSatisfy({ (0x21...0x7e).contains($0) && $0 != 44 }) else {
            throw ProxyError.localAuthentication
        }
        nonce = clientNonce + serverNonce
        serverFirst = "r=\(nonce),s=\(salt.base64EncodedString()),i=\(iterations)"
        let passwordKey = SymmetricKey(data: Data(password.utf8))
        var current = Data(HMAC<SHA256>.authenticationCode(for: salt + PostgreSQLWire.integer(1), using: passwordKey))
        var salted = [UInt8](current)
        for _ in 1..<iterations {
            current = Data(HMAC<SHA256>.authenticationCode(for: current, using: passwordKey))
            for (index, byte) in current.enumerated() { salted[index] ^= byte }
        }
        let key = SymmetricKey(data: salted)
        let clientKey = Data(HMAC<SHA256>.authenticationCode(for: Data("Client Key".utf8), using: key))
        storedKey = Data(SHA256.hash(data: clientKey))
        serverKey = Data(HMAC<SHA256>.authenticationCode(for: Data("Server Key".utf8), using: key))
    }

    func finish(_ clientFinal: String) throws -> String {
        guard clientFinal.utf8.count <= 4096 else { throw ProxyError.localAuthentication }
        let attributes = clientFinal.split(separator: ",", omittingEmptySubsequences: false)
        guard attributes.count == 3, attributes[0] == "c=\(channelBinding)", attributes[1] == "r=\(nonce)",
              attributes[2].hasPrefix("p="), let proof = Data(base64Encoded: String(attributes[2].dropFirst(2))), proof.count == 32 else {
            throw ProxyError.localAuthentication
        }
        let withoutProof = attributes.prefix(2).joined(separator: ",")
        let message = Data("\(clientFirstBare),\(serverFirst),\(withoutProof)".utf8)
        let signature = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: storedKey))
        let clientKey = Data(zip(proof, signature).map { $0 ^ $1 })
        let candidate = SHA256.hash(data: clientKey)
        guard zip(candidate, storedKey).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else {
            throw ProxyError.localAuthentication
        }
        let serverSignature = Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: serverKey)))
        return "v=\(serverSignature.base64EncodedString())"
    }

    static func authenticate(_ socket: PostgreSQLSocket, password: String) async throws {
        try await socket.send(PostgreSQLWire.authentication(10, data: Data("SCRAM-SHA-256\0\0".utf8)))
        let initial = try await socket.message()
        guard initial.type == 112, let zero = initial.body.firstIndex(of: 0),
              String(data: initial.body[..<zero], encoding: .utf8) == "SCRAM-SHA-256" else { throw ProxyError.localAuthentication }
        let payload = Data(initial.body[initial.body.index(after: zero)...])
        guard payload.count >= 4 else { throw ProxyError.localAuthentication }
        let count = Int(try PostgreSQLWire.uint32(Data(payload.prefix(4))))
        guard count <= 2048, payload.count == 4 + count,
              let clientFirst = String(data: payload.dropFirst(4), encoding: .utf8) else { throw ProxyError.localAuthentication }
        let salt = try ProxyRandom.bytes(16)
        let nonce = try ProxyRandom.bytes(24).base64EncodedString()
        let challenge = try await Task.detached(priority: .userInitiated) {
            try PostgreSQLSCRAM(password: password, clientFirst: clientFirst, salt: salt, serverNonce: nonce)
        }.value
        try Task.checkCancellation()
        try await socket.send(PostgreSQLWire.authentication(11, data: Data(challenge.serverFirst.utf8)))
        let final = try await socket.message()
        guard final.type == 112, let response = String(data: final.body, encoding: .utf8) else { throw ProxyError.localAuthentication }
        let serverFinal = try challenge.finish(response)
        try await socket.send(PostgreSQLWire.authentication(12, data: Data(serverFinal.utf8)))
    }
}
