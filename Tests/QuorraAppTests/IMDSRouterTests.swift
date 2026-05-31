import Foundation
import IAMIdentityCenter
import Testing
@testable import quorra

struct IMDSRouterTests {
    @Test func imdsv2TokenAllowsCredentialLookup() throws {
        var router = IMDSRouter(servedProfile: servedProfile, allowsIMDSv1: false)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let unauthenticated = router.response(for: request("GET", "/latest/meta-data/iam/security-credentials/"), now: now)
        #expect(unauthenticated.statusCode == 401)

        let tokenResponse = router.response(
            for: request(
                "PUT",
                "/latest/api/token",
                headers: ["x-aws-ec2-metadata-token-ttl-seconds": "21600"]
            ),
            now: now
        )
        #expect(tokenResponse.statusCode == 200)
        let token = try #require(String(data: tokenResponse.body, encoding: .utf8))

        let roleList = router.response(
            for: request(
                "GET",
                "/latest/meta-data/iam/security-credentials/",
                headers: ["x-aws-ec2-metadata-token": token]
            ),
            now: now
        )
        #expect(String(data: roleList.body, encoding: .utf8) == "OrganizationAdmin\n")

        let credentials = router.response(
            for: request(
                "GET",
                "/latest/meta-data/iam/security-credentials/OrganizationAdmin",
                headers: ["x-aws-ec2-metadata-token": token]
            ),
            now: now
        )
        #expect(credentials.statusCode == 200)

        let object = try JSONSerialization.jsonObject(with: credentials.body) as? [String: String]
        #expect(object?["Code"] == "Success")
        #expect(object?["Type"] == "AWS-HMAC")
        #expect(object?["AccessKeyId"] == "ASIA00000000EXMPL")
        #expect(object?["SecretAccessKey"] == "secret")
        #expect(object?["Token"] == "session-token")
    }

    @Test func imdsv1FallbackCanReadRegionAndRoleList() {
        var router = IMDSRouter(servedProfile: servedProfile, allowsIMDSv1: true)

        let region = router.response(for: request("GET", "/latest/meta-data/placement/region"))
        #expect(region.statusCode == 200)
        #expect(String(data: region.body, encoding: .utf8) == "us-east-2\n")

        let roleList = router.response(for: request("GET", "/latest/meta-data/iam/security-credentials"))
        #expect(roleList.statusCode == 200)
        #expect(String(data: roleList.body, encoding: .utf8) == "OrganizationAdmin\n")
    }

    @Test func expiredOrUnknownTokenIsRejected() throws {
        var router = IMDSRouter(servedProfile: servedProfile, allowsIMDSv1: false)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let tokenResponse = router.response(
            for: request(
                "PUT",
                "/latest/api/token",
                headers: ["x-aws-ec2-metadata-token-ttl-seconds": "1"]
            ),
            now: now
        )
        let token = try #require(String(data: tokenResponse.body, encoding: .utf8))

        let expired = router.response(
            for: request(
                "GET",
                "/latest/meta-data/placement/region",
                headers: ["x-aws-ec2-metadata-token": token]
            ),
            now: now.addingTimeInterval(2)
        )
        #expect(expired.statusCode == 401)
    }

    @Test func identityDocumentIncludesRegionAndAccount() throws {
        var router = IMDSRouter(servedProfile: servedProfile)
        let response = router.response(for: request("GET", "/latest/dynamic/instance-identity/document"))

        #expect(response.statusCode == 200)
        let object = try JSONSerialization.jsonObject(with: response.body) as? [String: String]
        #expect(object?["accountId"] == "699475923216")
        #expect(object?["region"] == "us-east-2")
        #expect(object?["privateIp"] == "127.0.0.1")
    }

    @MainActor
    @Test func localServerHandlesTokenAndCredentialRequests() async throws {
        let server = LocalIMDSServer(
            port: 0,
            servedProfile: servedProfile,
            onRequest: { _ in },
            onFailure: { _ in }
        )
        try await server.start()
        defer { server.stop() }

        var tokenRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(server.boundPort)/latest/api/token")!)
        tokenRequest.httpMethod = "PUT"
        tokenRequest.setValue("60", forHTTPHeaderField: "X-aws-ec2-metadata-token-ttl-seconds")
        let (tokenData, tokenURLResponse) = try await URLSession.shared.data(for: tokenRequest)
        let tokenResponse = try #require(tokenURLResponse as? HTTPURLResponse)
        #expect(tokenResponse.statusCode == 200)
        let token = try #require(String(data: tokenData, encoding: .utf8))

        var credentialsRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(server.boundPort)/latest/meta-data/iam/security-credentials/OrganizationAdmin")!)
        credentialsRequest.setValue(token, forHTTPHeaderField: "X-aws-ec2-metadata-token")
        let (credentialsData, credentialsURLResponse) = try await URLSession.shared.data(for: credentialsRequest)
        let credentialsResponse = try #require(credentialsURLResponse as? HTTPURLResponse)
        #expect(credentialsResponse.statusCode == 200)
        #expect(String(data: credentialsData, encoding: .utf8)?.contains("ASIA00000000EXMPL") == true)
    }

    private var servedProfile: IMDSServedProfile {
        IMDSServedProfile(
            profileName: "ac:cp:org_admin",
            sessionName: "astrocompute",
            accountId: "699475923216",
            roleName: "OrganizationAdmin",
            region: "us-east-2",
            credentials: RoleCredentials(
                accessKeyId: "ASIA00000000EXMPL",
                secretAccessKey: "secret",
                sessionToken: "session-token",
                expiresAt: Date(timeIntervalSince1970: 1_700_003_600),
                accountId: "699475923216",
                roleName: "OrganizationAdmin",
                region: "us-east-2",
                sessionName: "astrocompute",
                issuedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
    }

    private func request(
        _ method: String,
        _ path: String,
        headers: [String: String] = [:]
    ) -> IMDSHTTPRequest {
        IMDSHTTPRequest(method: method, path: path, headers: headers)
    }
}
