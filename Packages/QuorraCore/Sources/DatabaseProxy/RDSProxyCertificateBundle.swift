import CryptoKit
import Foundation

/// Official cross-signed variants of Amazon Root CA 1–4. The refresh script
/// verifies their signatures and equality to the canonical roots' public keys.
/// Explicit app anchors avoid system-root CT requirements for RDS Proxy's ACM
/// certificates. Chain, hostname, and validity verification remain mandatory.
nonisolated struct RDSProxyCertificateBundle: Sendable {
    static let sha256 = "48df7bb4f59bc2aefc9d8c00a48470fd9464b1a2b833b349d7ec678a1075631b"
    static let certificateCount = 4
    let certificates: [Data]

    init(bundle: Bundle = .module) throws {
        guard let url = bundle.url(forResource: "rds-proxy-amazon-roots", withExtension: "pem") else {
            throw DatabaseTLSError.missingCABundle
        }
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == Self.sha256 else { throw DatabaseTLSError.invalidCABundle }
        certificates = try RDSCertificateBundle.decodeCertificates(data)
        guard certificates.count == Self.certificateCount else { throw DatabaseTLSError.invalidCABundle }
    }
}
