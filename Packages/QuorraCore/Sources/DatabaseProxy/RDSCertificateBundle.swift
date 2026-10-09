import CryptoKit
import Foundation
import Security

/// Public CA roots downloaded from AWS, shipped inside the signed app bundle.
/// Scope: commercial AWS regions. GovCloud and China require separate bundles.
nonisolated struct RDSCertificateBundle: Sendable {
    static let sourceURL = "https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem"
    static let sha256 = "e5bb2084ccf45087bda1c9bffdea0eb15ee67f0b91646106e466714f9de3c7e3"
    static let certificateCount = 108
    let certificates: [Data]

    init(bundle: Bundle = .module) throws {
        guard let url = bundle.url(forResource: "rds-global-bundle", withExtension: "pem") else {
            throw DatabaseTLSError.missingCABundle
        }
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == Self.sha256 else { throw DatabaseTLSError.invalidCABundle }
        certificates = try Self.decodeRoots(data)
        guard certificates.count == Self.certificateCount else { throw DatabaseTLSError.invalidCABundle }
    }

    static func decodeRoots(_ pem: Data) throws -> [Data] {
        let roots = try decodeCertificates(pem)
        for der in roots {
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData),
                  let subject = SecCertificateCopyNormalizedSubjectSequence(certificate),
                  let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate),
                  subject as Data == issuer as Data else { throw DatabaseTLSError.invalidCABundle }
        }
        return roots
    }

    /// PEM parsing only. Callers must validate provenance/integrity before using
    /// certificates as anchors. Direct RDS additionally requires self-signed roots.
    static func decodeCertificates(_ pem: Data) throws -> [Data] {
        guard let text = String(data: pem, encoding: .ascii) else { throw DatabaseTLSError.invalidCABundle }
        var remainder = text[...]
        var roots: [Data] = []
        let begin = "-----BEGIN CERTIFICATE-----", end = "-----END CERTIFICATE-----"
        while !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            remainder = Substring(remainder.trimmingCharacters(in: .whitespacesAndNewlines))
            guard remainder.hasPrefix(begin), let finish = remainder.range(of: end) else { throw DatabaseTLSError.invalidCABundle }
            let encoded = remainder.dropFirst(begin.count)[..<finish.lowerBound].filter { !$0.isWhitespace }
            guard let der = Data(base64Encoded: String(encoded)),
                  SecCertificateCreateWithData(nil, der as CFData) != nil else { throw DatabaseTLSError.invalidCABundle }
            roots.append(der)
            remainder = remainder[finish.upperBound...]
        }
        guard !roots.isEmpty else { throw DatabaseTLSError.invalidCABundle }
        return roots
    }
}

nonisolated enum DatabaseTLSError: Error, LocalizedError {
    case missingCABundle, invalidCABundle, invalidHostname
    var errorDescription: String? {
        switch self {
        case .missingCABundle: "The RDS certificate bundle is missing. Reinstall Quorra."
        case .invalidCABundle: "The RDS certificate bundle could not be verified. Reinstall or update Quorra."
        case .invalidHostname: "Enter the database hostname used by its TLS certificate."
        }
    }
}

nonisolated enum DatabaseServerTrust {
    /// Applies both hostname and certificate-chain verification. Anchors belong
    /// only to this connection's trust evaluation, never to the user's Keychain.
    static func evaluate(_ trust: SecTrust, hostname: String, roots: [Data], diagnostics: DiagnosticLog = .disabled,
                         connectionID: UUID? = nil) -> Bool {
        guard !hostname.isEmpty, !roots.isEmpty else { return false }
        let anchors = roots.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard anchors.count == roots.count,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, hostname as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { return false }
        return verify(trust, diagnostics: diagnostics, connectionID: connectionID)
    }

    static func verify(_ trust: SecTrust, diagnostics: DiagnosticLog, connectionID: UUID?) -> Bool {
        var error: CFError?
        let verified = SecTrustEvaluateWithError(trust, &error)
        diagnostics.record(verified ? .tlsVerified : .tlsVerificationFailed, connectionID: connectionID,
                           error: verified ? nil : DatabaseCertificateFailure(status: error.map { Int32(clamping: CFErrorGetCode($0)) } ?? errSecNotTrusted))
        return verified
    }
}

nonisolated struct DatabaseCertificateFailure: Error, Sendable {
    let status: Int32
}
