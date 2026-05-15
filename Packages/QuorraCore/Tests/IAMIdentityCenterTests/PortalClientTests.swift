import Testing
import Foundation
@testable import IAMIdentityCenter

extension IAMIdentityCenterTestSuite {
@Suite("PortalClient", .serialized)
struct PortalClientTests {

    private let region = "us-east-1"
    private let baseURLSubstring = "portal.sso.us-east-1"

    private func makeClient() -> PortalClient {
        PortalClient(urlSession: StubURLProtocol.makeSession())
    }

    // MARK: - Helpers

    private func registerPortalSuccess(urlSubstring: String, statusCode: Int = 200, json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        let url = URL(string: "https://portal.sso.us-east-1.amazonaws.com\(urlSubstring)")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        StubURLProtocol.register(urlSubstring: urlSubstring, response: .success(data, response))
    }

    private func registerPortalAWSError(urlSubstring: String, statusCode: Int = 403, type: String, message: String? = nil) throws {
        var json: [String: Any] = ["__type": type]
        if let message { json["message"] = message }
        let data = try JSONSerialization.data(withJSONObject: json)
        let url = URL(string: "https://portal.sso.us-east-1.amazonaws.com\(urlSubstring)")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        StubURLProtocol.register(urlSubstring: urlSubstring, response: .success(data, response))
    }

    private func registerPortal5xx(urlSubstring: String, statusCode: Int = 500) {
        let url = URL(string: "https://portal.sso.us-east-1.amazonaws.com\(urlSubstring)")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        StubURLProtocol.register(urlSubstring: urlSubstring, response: .success(Data(), response))
    }

    // MARK: - GetRoleCredentials — success

    @Test("getRoleCredentials - success decodes all MintedCredential fields correctly")
    func getRoleCredentialsSuccess() async throws {
        StubURLProtocol.reset()

        // expiration is Unix milliseconds per Portal API reference
        let expirationMs: Int64 = 1700003600_000 // 1700003600 seconds * 1000

        try registerPortalSuccess(
            urlSubstring: "/federation/credentials",
            json: [
                "roleCredentials": [
                    "accessKeyId": "ASIAIOSFODNN7EXAMPLE",
                    "secretAccessKey": "test-default-secret-key",
                    "sessionToken": "AQoDYXdzEJr//////////stub-token",
                    "expiration": expirationMs
                ]
            ]
        )

        let client = makeClient()
        let creds = try await client.getRoleCredentials(
            accessToken: "test-token",
            accountId: "123456789012",
            roleName: "ReadOnly",
            region: region
        )

        // Wire-response fields only — provenance (accountId, roleName, region, sessionName,
        // issuedAt) is attached by the actor in a later chunk when constructing RoleCredentials.
        #expect(creds.accessKeyId == "ASIAIOSFODNN7EXAMPLE")
        #expect(creds.secretAccessKey == "test-default-secret-key")
        #expect(creds.sessionToken == "AQoDYXdzEJr//////////stub-token")

        // expiration is milliseconds on the wire; verify conversion to Date (divide by 1000)
        let expectedExpiry = Date(timeIntervalSince1970: TimeInterval(expirationMs) / 1000.0)
        #expect(creds.expiresAt == expectedExpiry)
    }

    @Test("getRoleCredentials - expiration milliseconds conversion is correct")
    func getRoleCredentialsExpirationMilliseconds() async throws {
        StubURLProtocol.reset()

        // Use a distinctive value to verify the divide-by-1000 conversion
        // 1_700_000_000_000 ms = 1_700_000_000 s
        let expirationMs: Int64 = 1_700_000_000_000
        let expectedSeconds: TimeInterval = 1_700_000_000

        try registerPortalSuccess(
            urlSubstring: "/federation/credentials",
            json: [
                "roleCredentials": [
                    "accessKeyId": "KEY",
                    "secretAccessKey": "SECRET",
                    "sessionToken": "TOKEN",
                    "expiration": expirationMs
                ]
            ]
        )

        let client = makeClient()
        let creds = try await client.getRoleCredentials(
            accessToken: "tok",
            accountId: "123456789012",
            roleName: "Role",
            region: region
        )

        #expect(creds.expiresAt.timeIntervalSince1970 == expectedSeconds)
    }

    // MARK: - GetRoleCredentials — error mapping

    @Test("getRoleCredentials - ForbiddenException maps to roleNotAssigned")
    func getRoleCredentialsForbidden() async throws {
        StubURLProtocol.reset()
        try registerPortalAWSError(
            urlSubstring: "/federation/credentials",
            statusCode: 403,
            type: "ForbiddenException",
            message: "Access denied to role"
        )

        let client = makeClient()
        await #expect(performing: {
            try await client.getRoleCredentials(
                accessToken: "tok",
                accountId: "123456789012",
                roleName: "Role",
                region: region
            )
        }, throws: { error in
            guard case .roleNotAssigned = error as? IAMIdentityCenterError else { return false }
            return true
        })
    }

    @Test("getRoleCredentials - ResourceNotFoundException maps to accountNotFound")
    func getRoleCredentialsResourceNotFound() async throws {
        StubURLProtocol.reset()
        try registerPortalAWSError(
            urlSubstring: "/federation/credentials",
            statusCode: 404,
            type: "ResourceNotFoundException",
            message: "Account does not exist"
        )

        let client = makeClient()
        await #expect(performing: {
            try await client.getRoleCredentials(
                accessToken: "tok",
                accountId: "123456789012",
                roleName: "Role",
                region: region
            )
        }, throws: { error in
            guard case .accountNotFound = error as? IAMIdentityCenterError else { return false }
            return true
        })
    }

    @Test("getRoleCredentials - 5xx maps to httpStatus (transient)")
    func getRoleCredentials5xx() async throws {
        StubURLProtocol.reset()
        registerPortal5xx(urlSubstring: "/federation/credentials", statusCode: 503)

        let client = makeClient()
        await #expect(performing: {
            try await client.getRoleCredentials(
                accessToken: "tok",
                accountId: "123456789012",
                roleName: "Role",
                region: region
            )
        }, throws: { error in
            guard case .httpStatus(let code, _) = error as? IAMIdentityCenterError else { return false }
            return code == 503
        })
    }

    @Test("getRoleCredentials - network failure maps to .network")
    func getRoleCredentialsNetworkFailure() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.register(
            urlSubstring: "/federation/credentials",
            response: .failure(URLError(.notConnectedToInternet))
        )

        let client = makeClient()
        await #expect(performing: {
            try await client.getRoleCredentials(
                accessToken: "tok",
                accountId: "123456789012",
                roleName: "Role",
                region: region
            )
        }, throws: { error in
            guard case .network = error as? IAMIdentityCenterError else { return false }
            return true
        })
    }

    @Test("getRoleCredentials - unknown AWS error code passes through as .awsError")
    func getRoleCredentialsUnknownAWSError() async throws {
        StubURLProtocol.reset()
        try registerPortalAWSError(
            urlSubstring: "/federation/credentials",
            statusCode: 400,
            type: "ThrottlingException",
            message: "Rate exceeded"
        )

        let client = makeClient()
        await #expect(performing: {
            try await client.getRoleCredentials(
                accessToken: "tok",
                accountId: "123456789012",
                roleName: "Role",
                region: region
            )
        }, throws: { error in
            guard case .awsError(let code, let desc) = error as? IAMIdentityCenterError else { return false }
            return code == "ThrottlingException" && desc == "Rate exceeded"
        })
    }

    // MARK: - ListAccounts — success + pagination

    @Test("listAccounts - single page returns flat array")
    func listAccountsSinglePage() async throws {
        StubURLProtocol.reset()
        try registerPortalSuccess(
            urlSubstring: "/assignment/accounts",
            json: [
                "accountList": [
                    ["accountId": "111111111111", "accountName": "dev", "emailAddress": "dev@example.com"],
                    ["accountId": "222222222222", "accountName": "prod", "emailAddress": "prod@example.com"],
                ]
                // No nextToken — single page
            ]
        )

        let client = makeClient()
        let accounts = try await client.listAccounts(accessToken: "tok", region: region)

        #expect(accounts.count == 2)
        #expect(accounts[0].accountId == "111111111111")
        #expect(accounts[0].accountName == "dev")
        #expect(accounts[1].accountId == "222222222222")
    }

    @Test("listAccounts - pagination loops until no nextToken")
    func listAccountsPagination() async throws {
        StubURLProtocol.reset()

        // Page 1 returns nextToken
        var callCount = 0
        StubURLProtocol.registerCustom(urlSubstring: "/assignment/accounts") { _ in
            callCount += 1
            let json: [String: Any]
            if callCount == 1 {
                json = [
                    "accountList": [["accountId": "111111111111", "accountName": "p1", "emailAddress": "p1@x.com"]],
                    "nextToken": "page2token"
                ]
            } else {
                json = [
                    "accountList": [["accountId": "222222222222", "accountName": "p2", "emailAddress": "p2@x.com"]]
                    // No nextToken — last page
                ]
            }
            let data = try! JSONSerialization.data(withJSONObject: json)
            let url = URL(string: "https://portal.sso.us-east-1.amazonaws.com/assignment/accounts")!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (data, response)
        }

        let client = makeClient()
        let accounts = try await client.listAccounts(accessToken: "tok", region: region)

        #expect(accounts.count == 2)
        #expect(accounts.map(\.accountId).contains("111111111111"))
        #expect(accounts.map(\.accountId).contains("222222222222"))
    }

    @Test("listAccounts - empty accountList returns empty array")
    func listAccountsEmpty() async throws {
        StubURLProtocol.reset()
        try registerPortalSuccess(
            urlSubstring: "/assignment/accounts",
            json: ["accountList": [String]()]
        )

        let client = makeClient()
        let accounts = try await client.listAccounts(accessToken: "tok", region: region)
        #expect(accounts.isEmpty)
    }

    // MARK: - ListAccountRoles — success + pagination

    @Test("listAccountRoles - single page returns flat array")
    func listAccountRolesSinglePage() async throws {
        StubURLProtocol.reset()
        try registerPortalSuccess(
            urlSubstring: "/assignment/roles",
            json: [
                "roleList": [
                    ["accountId": "123456789012", "roleName": "ReadOnly"],
                    ["accountId": "123456789012", "roleName": "Admin"],
                ]
            ]
        )

        let client = makeClient()
        let roles = try await client.listAccountRoles(
            accessToken: "tok",
            accountId: "123456789012",
            region: region
        )

        #expect(roles.count == 2)
        #expect(roles[0].roleName == "ReadOnly")
        #expect(roles[1].roleName == "Admin")
    }

    @Test("listAccountRoles - pagination loops until no nextToken")
    func listAccountRolesPagination() async throws {
        StubURLProtocol.reset()

        var callCount = 0
        StubURLProtocol.registerCustom(urlSubstring: "/assignment/roles") { _ in
            callCount += 1
            let json: [String: Any]
            if callCount == 1 {
                json = [
                    "roleList": [["accountId": "123456789012", "roleName": "RoleA"]],
                    "nextToken": "rolespage2"
                ]
            } else {
                json = [
                    "roleList": [["accountId": "123456789012", "roleName": "RoleB"]]
                ]
            }
            let data = try! JSONSerialization.data(withJSONObject: json)
            let url = URL(string: "https://portal.sso.us-east-1.amazonaws.com/assignment/roles")!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (data, response)
        }

        let client = makeClient()
        let roles = try await client.listAccountRoles(
            accessToken: "tok",
            accountId: "123456789012",
            region: region
        )

        #expect(roles.count == 2)
        #expect(roles.map(\.roleName).contains("RoleA"))
        #expect(roles.map(\.roleName).contains("RoleB"))
    }

    // MARK: - Request encoding

    @Test("getRoleCredentials - request includes bearer token header")
    func getRoleCredentialsBearerHeader() async throws {
        StubURLProtocol.reset()

        var capturedRequest: URLRequest?
        StubURLProtocol.registerCustom(urlSubstring: "/federation/credentials") { request in
            capturedRequest = request
            let json: [String: Any] = [
                "roleCredentials": [
                    "accessKeyId": "KEY", "secretAccessKey": "SECRET",
                    "sessionToken": "TOKEN", "expiration": 1_700_000_000_000
                ]
            ]
            let data = try! JSONSerialization.data(withJSONObject: json)
            let url = URL(string: "https://portal.sso.us-east-1.amazonaws.com/federation/credentials")!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (data, response)
        }

        let client = makeClient()
        _ = try await client.getRoleCredentials(
            accessToken: "my-bearer-token",
            accountId: "123456789012",
            roleName: "Role",
            region: region
        )

        #expect(capturedRequest?.value(forHTTPHeaderField: "x-amz-sso_bearer_token") == "my-bearer-token")
        #expect(capturedRequest?.httpMethod == "GET")
    }

    @Test("getRoleCredentials - URL contains correct query params")
    func getRoleCredentialsURLQueryParams() async throws {
        StubURLProtocol.reset()

        var capturedRequest: URLRequest?
        StubURLProtocol.registerCustom(urlSubstring: "/federation/credentials") { request in
            capturedRequest = request
            let json: [String: Any] = [
                "roleCredentials": [
                    "accessKeyId": "KEY", "secretAccessKey": "SECRET",
                    "sessionToken": "TOKEN", "expiration": 1_700_000_000_000
                ]
            ]
            let data = try! JSONSerialization.data(withJSONObject: json)
            let url = URL(string: "https://portal.sso.us-east-1.amazonaws.com/federation/credentials")!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (data, response)
        }

        let client = makeClient()
        _ = try await client.getRoleCredentials(
            accessToken: "tok",
            accountId: "123456789012",
            roleName: "MyReadOnlyRole",
            region: region
        )

        let urlString = capturedRequest?.url?.absoluteString ?? ""
        #expect(urlString.contains("account_id=123456789012"))
        #expect(urlString.contains("role_name=MyReadOnlyRole"))
    }

    // MARK: - Malformed response

    @Test("getRoleCredentials - malformed JSON response maps to .malformedResponse")
    func getRoleCredentialsMalformedJSON() async throws {
        StubURLProtocol.reset()

        let url = URL(string: "https://portal.sso.us-east-1.amazonaws.com/federation/credentials")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        StubURLProtocol.register(
            urlSubstring: "/federation/credentials",
            response: .success(Data("not-json".utf8), response)
        )

        let client = makeClient()
        await #expect(performing: {
            try await client.getRoleCredentials(
                accessToken: "tok",
                accountId: "123456789012",
                roleName: "Role",
                region: region
            )
        }, throws: { error in
            guard case .malformedResponse = error as? IAMIdentityCenterError else { return false }
            return true
        })
    }
}
}
