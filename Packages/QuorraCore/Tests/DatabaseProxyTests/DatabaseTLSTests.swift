import Foundation
import Security
import Testing
@testable import DatabaseProxy

struct DatabaseTLSTests {
    @Test func signedAppContainsTheReviewedAWSRootBundle() throws {
        let bundle = try RDSCertificateBundle()
        #expect(bundle.certificates.count == RDSCertificateBundle.certificateCount)
        #expect(Set(bundle.certificates).count == bundle.certificates.count)
        for data in bundle.certificates {
            let certificate = try #require(SecCertificateCreateWithData(nil, data as CFData))
            let name = try #require(SecCertificateCopySubjectSummary(certificate) as String?)
            #expect(name.hasPrefix("Amazon RDS "))
            #expect(name.contains("Root CA"))
        }
    }

    @Test func parserRejectsMissingMalformedAndNonRootCertificates() throws {
        let leaf = try fixture("server")
        let pem = "-----BEGIN CERTIFICATE-----\n\(leaf.base64EncodedString())\n-----END CERTIFICATE-----\n"
        for data in [Data(), Data("not a certificate".utf8), Data("-----BEGIN CERTIFICATE-----\ninvalid\n-----END CERTIFICATE-----".utf8), Data(pem.utf8)] {
            #expect(throws: DatabaseTLSError.self) { try RDSCertificateBundle.decodeRoots(data) }
        }
    }

    @Test func proxyBundleContainsOnlyReviewedAmazonRootVariants() throws {
        let bundle = try RDSProxyCertificateBundle()
        #expect(bundle.certificates.count == 4)
        #expect(Set(bundle.certificates).count == 4)
        for (index, data) in bundle.certificates.enumerated() {
            let certificate = try #require(SecCertificateCreateWithData(nil, data as CFData))
            #expect(SecCertificateCopySubjectSummary(certificate) as String? == "Amazon Root CA \(index + 1)")
            #expect(SecCertificateCopyNormalizedSubjectSequence(certificate) != SecCertificateCopyNormalizedIssuerSequence(certificate))
        }
        _ = try DatabaseTLSOptions.make(hostname: "example.proxy-abc.eu-west-2.rds.amazonaws.com", trust: .rdsProxy)
        #expect(DatabaseTLSOptions.isRDSProxyEndpoint("example.proxy-abc.eu-west-2.rds.amazonaws.com"))
        #expect(!DatabaseTLSOptions.isRDSProxyEndpoint("example.proxy-abc.eu-west-2.rds.amazonaws.com.attacker.test"))
        #expect(!DatabaseTLSOptions.isRDSProxyEndpoint("example.cluster-abc.eu-west-2.rds.amazonaws.com"))
    }

    @Test func trustAcceptsMatchingHostAndRejectsWrongHostExpiredLeafAndUntrustedRoot() throws {
        let root = try fixture("root")
        #expect(try evaluate(leaf: "server", hostname: "db.example.test", roots: [root]))
        #expect(try !evaluate(leaf: "server", hostname: "wrong.example.test", roots: [root]))
        #expect(try !evaluate(leaf: "expired", hostname: "db.example.test", roots: [root]))
        #expect(try !evaluate(leaf: "server", hostname: "db.example.test", roots: [fixture("other-root")]))
        #expect(try !evaluate(leaf: "server", hostname: "db.example.test", roots: []))
    }

    @Test func tlsOptionsLoadRDSRootsAndRejectInvalidServerNames() throws {
        _ = try DatabaseTLSOptions.make(hostname: "example.eu-west-2.rds.amazonaws.com", trust: .rds)
        _ = try DatabaseTLSOptions.make(hostname: "example.proxy.eu-west-2.rds.amazonaws.com", trust: .system)
        for name in ["", "https://example.com", "user@example.com", "bad host", "bad\0host"] {
            #expect(throws: DatabaseTLSError.self) { try DatabaseTLSOptions.make(hostname: name, trust: .rds) }
        }
    }

    private func evaluate(leaf: String, hostname: String, roots: [Data]) throws -> Bool {
        let certificate = try #require(SecCertificateCreateWithData(nil, fixture(leaf) as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, hostname as CFString), &trust) == errSecSuccess)
        let result = try #require(trust)
        // Fixed verification date keeps public synthetic fixtures deterministic.
        #expect(SecTrustSetVerifyDate(result, Date(timeIntervalSince1970: 1_790_035_200) as CFDate) == errSecSuccess)
        return DatabaseServerTrust.evaluate(result, hostname: hostname, roots: roots)
    }

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle.module
        let url = try #require(bundle.url(forResource: name, withExtension: "der"))
        return try Data(contentsOf: url)
    }
}
