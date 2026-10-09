import Foundation
import Network
import Security

nonisolated enum DatabaseTLSOptions {
    enum TrustSource: String, Codable, CaseIterable, Identifiable, Sendable {
        case system, rds, rdsProxy
        var id: String { rawValue }
        var title: String {
            switch self {
            case .rds: "Amazon RDS certificates"
            case .rdsProxy: "Amazon RDS Proxy certificates"
            case .system: "System certificates"
            }
        }
    }

    /// For the upstream protocol handshake. PostgreSQL negotiates its SSLRequest
    /// before inserting these TLS options into the connection's protocol stack.
    static func make(hostname: String, trust: TrustSource, diagnostics: DiagnosticLog = .disabled,
                     connectionID: UUID? = nil) throws -> NWProtocolTLS.Options {
        guard !hostname.isEmpty, !hostname.contains(where: { $0.isWhitespace || $0 == "\0" }),
              !hostname.contains("/"), !hostname.contains("@") else { throw DatabaseTLSError.invalidHostname }
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, hostname)
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_tls_sct_enabled(options.securityProtocolOptions, true)
        sec_protocol_options_set_tls_ocsp_enabled(options.securityProtocolOptions, true)
        switch trust {
        case .system:
            // Keep the system's complete policy, including Certificate
            // Transparency. Only extract its numeric failure for diagnostics.
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
                let reference = sec_trust_copy_ref(trust).takeRetainedValue()
                complete(DatabaseServerTrust.verify(reference, diagnostics: diagnostics, connectionID: connectionID))
            }, DispatchQueue(label: "dev.ajbeck.quorra.system-trust", qos: .utility))
        case .rds, .rdsProxy:
            let roots = try trust == .rds ? RDSCertificateBundle().certificates : RDSProxyCertificateBundle().certificates
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
                let reference = sec_trust_copy_ref(trust).takeRetainedValue()
                complete(DatabaseServerTrust.evaluate(reference, hostname: hostname, roots: roots,
                                                      diagnostics: diagnostics, connectionID: connectionID))
            }, DispatchQueue(label: "dev.ajbeck.quorra.rds-trust", qos: .utility))
        }
        return options
    }

    static func isRDSProxyEndpoint(_ hostname: String) -> Bool {
        let host = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return host.hasSuffix(".rds.amazonaws.com") && host.split(separator: ".").contains { $0.hasPrefix("proxy-") }
    }
}
