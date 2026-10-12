import CommonCrypto
import CryptoKit
import Foundation

/// Upstream authentication state. IAM accepts only the password challenge over
/// verified TLS; a configured password may use SCRAM, MD5 or a password request.
nonisolated struct PostgreSQLPasswordAuthentication: Sendable {
    private enum State: Sendable { case initial, passwordSent, saslStarted, proofSent, proofVerified, complete }
    private var state = State.initial
    private let login: DatabaseLogin
    private let iam: Bool
    private let clientNonce: String
    private var scram: PostgreSQLSCRAMClient?
    var complete: Bool { if case .complete = state { true } else { false } }

    init(login: DatabaseLogin, iam: Bool, nonce: String? = nil) throws {
        self.login = login
        self.iam = iam
        self.clientNonce = try nonce ?? ProxyRandom.bytes(24).base64EncodedString()
    }

    mutating func respond(to body: Data) throws -> Data? {
        guard body.count >= 4 else { throw ProxyError.malformedMessage }
        let method = try PostgreSQLWire.uint32(Data(body.prefix(4)))
        let extra = Data(body.dropFirst(4))
        switch (state, method) {
        case (.initial, 3):
            guard extra.isEmpty else { throw ProxyError.malformedMessage }
            state = .passwordSent
            return Data(login.password.utf8) + Data([0])
        case (.initial, 5) where !iam:
            guard extra.count == 4 else { throw ProxyError.malformedMessage }
            let inner = Self.md5(Data((login.password + login.username).utf8))
            state = .passwordSent
            return Data(("md5" + Self.md5(Data(inner.utf8) + extra)).utf8) + Data([0])
        case (.initial, 10) where !iam:
            guard extra.count <= 4096, extra.suffix(2) == Data([0, 0]),
                  let text = String(data: extra, encoding: .utf8),
                  text.split(separator: "\0").contains("SCRAM-SHA-256") else {
                throw ProxyError.unsupportedAuthentication
            }
            scram = try PostgreSQLSCRAMClient(nonce: clientNonce)
            let first = Data(scram!.first.utf8)
            state = .saslStarted
            return Data("SCRAM-SHA-256\0".utf8) + PostgreSQLWire.integer(UInt32(first.count)) + first
        case (.saslStarted, 11):
            guard let challenge = String(data: extra, encoding: .utf8) else { throw ProxyError.malformedMessage }
            let response = try scram!.respond(password: login.password, challenge: challenge)
            state = .proofSent
            return Data(response.utf8)
        case (.proofSent, 12):
            guard let final = String(data: extra, encoding: .utf8) else { throw ProxyError.malformedMessage }
            try scram!.verify(final)
            state = .proofVerified
            return nil
        case (.passwordSent, 0), (.proofVerified, 0):
            guard extra.isEmpty else { throw ProxyError.malformedMessage }
            state = .complete
            return nil
        default:
            // AuthenticationOk without a credential exchange is not proof that
            // a saved password works. Do not silently accept trust/peer auth.
            throw iam ? ProxyError.upstreamAuthentication : ProxyError.upstreamPasswordAuthentication
        }
    }

    private static func md5(_ bytes: Data) -> String {
        Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct PostgreSQLSCRAMClient: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let nonce: String
    private var expectedServerSignature: Data?
    private var firstBare: String { "n=,r=\(nonce)" }
    var first: String { "n,,\(firstBare)" }
    var description: String { "PostgreSQLSCRAMClient(redacted)" }
    var debugDescription: String { description }

    init(nonce: String) throws {
        guard (16...512).contains(nonce.utf8.count), nonce.utf8.allSatisfy({ (33...126).contains($0) && $0 != 44 }) else {
            throw ProxyError.upstreamPasswordAuthentication
        }
        self.nonce = nonce
    }

    mutating func respond(password: String, challenge: String) throws -> String {
        let fields = try Self.attributes(challenge)
        guard fields["m"] == nil, let serverNonce = fields["r"], serverNonce.hasPrefix(nonce),
              serverNonce.count > nonce.count, serverNonce.utf8.count <= 1024,
              serverNonce.utf8.allSatisfy({ (33...126).contains($0) && $0 != 44 }),
              let encodedSalt = fields["s"], let salt = Data(base64Encoded: encodedSalt), (1...1024).contains(salt.count),
              let encodedRounds = fields["i"], encodedRounds.utf8.allSatisfy({ (48...57).contains($0) }),
              let rounds = UInt32(encodedRounds), (4096...1_000_000).contains(rounds), expectedServerSignature == nil else {
            throw ProxyError.upstreamPasswordAuthentication
        }
        let prepared = PostgreSQLSASLPrep.password(password)
        var derived = [UInt8](repeating: 0, count: 32)
        let result = prepared.withCString { bytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes, prepared.utf8.count,
                                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &derived, 32)
            }
        }
        guard result == kCCSuccess else { throw ProxyError.upstreamPasswordAuthentication }
        let key = SymmetricKey(data: derived)
        let clientKey = Data(HMAC<SHA256>.authenticationCode(for: Data("Client Key".utf8), using: key))
        let final = "c=biws,r=\(serverNonce)"
        let message = Data("\(firstBare),\(challenge),\(final)".utf8)
        let signature = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: SHA256.hash(data: clientKey)))
        let proof = Data(zip(clientKey, signature).map { $0 ^ $1 }).base64EncodedString()
        let serverKey = HMAC<SHA256>.authenticationCode(for: Data("Server Key".utf8), using: key)
        expectedServerSignature = Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: serverKey)))
        return "\(final),p=\(proof)"
    }

    func verify(_ final: String) throws {
        let fields = try Self.attributes(final)
        guard fields["e"] == nil, let value = fields["v"], let received = Data(base64Encoded: value),
              let expectedServerSignature, received.count == expectedServerSignature.count,
              zip(received, expectedServerSignature).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else {
            throw ProxyError.upstreamPasswordAuthentication
        }
    }

    private static func attributes(_ text: String) throws -> [String: String] {
        guard text.utf8.count <= 4096 else { throw ProxyError.malformedMessage }
        var result: [String: String] = [:]
        for field in text.split(separator: ",", omittingEmptySubsequences: false) {
            guard field.utf8.count >= 3, field.dropFirst().first == "=" else { throw ProxyError.malformedMessage }
            let key = String(field.prefix(1))
            guard result[key] == nil else { throw ProxyError.malformedMessage }
            result[key] = String(field.dropFirst(2))
        }
        return result
    }
}
