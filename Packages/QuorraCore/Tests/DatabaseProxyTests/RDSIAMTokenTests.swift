import CryptoKit
import Foundation
import Testing
@testable import DatabaseProxy
import IAMIdentityCenter

struct RDSIAMTokenTests {
    @Test func tokenSignatureMatchesIndependentSigV4Calculation() async throws {
        let credentials = RoleCredentials(accessKeyId: "AKIDEXAMPLE", secretAccessKey: "synthetic-test-secret",
            sessionToken: "synthetic+session/token=", expiresAt: Date.now.addingTimeInterval(3600), accountId: "123456789012",
            roleName: "Example", region: "eu-west-2", sessionName: "Synthetic", issuedAt: .now)
        let host = "example.abcdefghijkl.eu-west-2.rds.amazonaws.com"
        let token = try await RDSIAMTokenGenerator().generate(credentials: credentials, host: host, port: 5432, region: "eu-west-2", username: "user+name")
        let components = try #require(URLComponents(string: "https://" + token))
        let items = try #require(components.queryItems)
        func value(_ key: String) throws -> String { try #require(items.first { $0.name == key }?.value) }
        #expect(components.host == host)
        #expect(components.port == 5432)
        #expect(try value("Action") == "connect")
        #expect(try value("DBUser") == "user+name")
        #expect(try value("X-Amz-Security-Token") == credentials.sessionToken)
        #expect(try value("X-Amz-Expires") == "900")
        let timestamp = try value("X-Amz-Date")
        let day = String(timestamp.prefix(8))
        let scope = "\(day)/eu-west-2/rds-db/aws4_request"
        #expect(try value("X-Amz-Credential") == "AKIDEXAMPLE/\(scope)")
        // SigV4 URI-encodes each decoded name/value before sorting. The wire URL
        // may contain a literal '+', which canonicalization must encode as %2B.
        // https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let query = items.filter { $0.name != "X-Amz-Signature" }.map {
            $0.name.addingPercentEncoding(withAllowedCharacters: unreserved)! + "=" +
                ($0.value ?? "").addingPercentEncoding(withAllowedCharacters: unreserved)!
        }.sorted().joined(separator: "&")
        let request = "GET\n/\n\(query)\nhost:\(host):5432\n\nhost\n\(sha256(""))"
        let stringToSign = "AWS4-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(sha256(request))"
        let dateKey = hmac(Data(("AWS4" + credentials.secretAccessKey).utf8), day)
        let regionKey = hmac(dateKey, "eu-west-2")
        let serviceKey = hmac(regionKey, "rds-db")
        let signingKey = hmac(serviceKey, "aws4_request")
        #expect(try value("X-Amz-Signature") == hex(hmac(signingKey, stringToSign)))
    }

    @Test func expiringRoleCannotProduceAnUnusableToken() async {
        let credentials = RoleCredentials(accessKeyId: "AKIDEXAMPLE", secretAccessKey: "synthetic", sessionToken: "synthetic",
            expiresAt: .now, accountId: "123456789012", roleName: "Example", region: "eu-west-2", sessionName: "Synthetic", issuedAt: .now)
        await #expect(throws: IAMIdentityCenterError.tokenExpired) {
            try await RDSIAMTokenGenerator().generate(credentials: credentials, host: "example.rds.amazonaws.com", port: 5432, region: "eu-west-2", username: "app")
        }
    }

    private func hmac(_ key: Data, _ value: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key)))
    }
    private func sha256(_ value: String) -> String { hex(Data(SHA256.hash(data: Data(value.utf8)))) }
    private func hex(_ value: Data) -> String { value.map { String(format: "%02x", $0) }.joined() }
}
