import Darwin
import Foundation
import IAMIdentityCenter
import Testing
@testable import QuorraAppLogic

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
        #expect(String(data: roleList.body, encoding: .utf8) == "OrganizationAdmin")

        let credentialsRoute = router.route(
            for: request(
                "GET",
                "/latest/meta-data/iam/security-credentials/OrganizationAdmin",
                headers: ["x-aws-ec2-metadata-token": token]
            ),
            now: now
        )
        guard case .credentialDocument = credentialsRoute else {
            Issue.record("Expected an authenticated credential-document route")
            return
        }
        let credentials = router.credentialsResponse(using: servedCredentials)
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
        #expect(String(data: region.body, encoding: .utf8) == "us-east-2")

        let roleList = router.response(for: request("GET", "/latest/meta-data/iam/security-credentials"))
        #expect(roleList.statusCode == 200)
        #expect(String(data: roleList.body, encoding: .utf8) == "OrganizationAdmin")
    }

    @Test func scalarMetadataResponsesMatchCanonicalIMDSPathsWithoutTrailingNewlines() {
        var router = IMDSRouter(servedProfile: servedProfile)
        let expectedBodies = [
            "/latest/meta-data/iam/security-credentials/": "OrganizationAdmin",
            "/latest/meta-data/placement/availability-zone": "us-east-2a",
            "/latest/meta-data/placement/region": "us-east-2",
            "/latest/meta-data/services/domain": "amazonaws.com",
            "/latest/meta-data/services/partition": "aws",
        ]

        for (path, expectedBody) in expectedBodies {
            let response = router.response(for: request("GET", path))
            #expect(response.statusCode == 200)
            #expect(String(data: response.body, encoding: .utf8) == expectedBody)
            #expect(response.body.last != 0x0A)
        }
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
            initialCredentials: servedCredentials,
            credentialProvider: { self.servedCredentials },
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

    @MainActor
    @Test func runningServerServesRenewedCredentialsWithoutRestart() async throws {
        let now = Date()
        let initialCredentials = makeCredentials(
            accessKeyId: "ASIAFIRSTCREDENTIAL",
            issuedAt: now.addingTimeInterval(-570),
            expiresAt: now.addingTimeInterval(30)
        )
        let provider = StubIMDSCredentialProvider(results: [
            .success(makeCredentials(accessKeyId: "ASIARENEWEDCREDENT")),
        ])
        let server = LocalIMDSServer(
            port: 0,
            servedProfile: servedProfile,
            initialCredentials: initialCredentials,
            credentialProvider: { try await provider.credentials() },
            onRequest: { _ in },
            onFailure: { _ in }
        )
        try await server.start()
        defer { server.stop() }
        let originalPort = server.boundPort
        let url = try #require(URL(
            string: "http://127.0.0.1:\(originalPort)/latest/meta-data/iam/security-credentials/OrganizationAdmin"
        ))

        await provider.waitUntilCallCount(1)

        var renewedData = Data()
        var renewedURLResponse: URLResponse?
        for _ in 0..<20 {
            (renewedData, renewedURLResponse) = try await URLSession.shared.data(from: url)
            if String(data: renewedData, encoding: .utf8)?.contains("ASIARENEWEDCREDENT") == true {
                break
            }
            await Task.yield()
        }
        let renewedResponse = try #require(renewedURLResponse as? HTTPURLResponse)
        #expect(renewedResponse.statusCode == 200)
        #expect(String(data: renewedData, encoding: .utf8)?.contains("ASIARENEWEDCREDENT") == true)
        #expect(server.boundPort == originalPort)
        #expect(provider.callCount == 1)
    }

    @MainActor
    @Test func freshCredentialCacheAvoidsProviderForAllRequestTypes() async throws {
        let provider = StubIMDSCredentialProvider(results: [
            .success(servedCredentials),
        ])
        let server = LocalIMDSServer(
            port: 0,
            servedProfile: servedProfile,
            allowsIMDSv1: false,
            initialCredentials: servedCredentials,
            credentialProvider: { try await provider.credentials() },
            onRequest: { _ in },
            onFailure: { _ in }
        )
        try await server.start()
        defer { server.stop() }

        let credentialURL = try #require(URL(
            string: "http://127.0.0.1:\(server.boundPort)/latest/meta-data/iam/security-credentials/OrganizationAdmin"
        ))
        let (_, unauthorizedURLResponse) = try await URLSession.shared.data(from: credentialURL)
        let unauthorizedResponse = try #require(unauthorizedURLResponse as? HTTPURLResponse)
        #expect(unauthorizedResponse.statusCode == 401)
        #expect(provider.callCount == 0)

        var tokenRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(server.boundPort)/latest/api/token")!)
        tokenRequest.httpMethod = "PUT"
        tokenRequest.setValue("60", forHTTPHeaderField: "X-aws-ec2-metadata-token-ttl-seconds")
        let (tokenData, _) = try await URLSession.shared.data(for: tokenRequest)
        let token = try #require(String(data: tokenData, encoding: .utf8))

        var regionRequest = URLRequest(url: URL(
            string: "http://127.0.0.1:\(server.boundPort)/latest/meta-data/placement/region"
        )!)
        regionRequest.setValue(token, forHTTPHeaderField: "X-aws-ec2-metadata-token")
        let (_, regionURLResponse) = try await URLSession.shared.data(for: regionRequest)
        let regionResponse = try #require(regionURLResponse as? HTTPURLResponse)
        #expect(regionResponse.statusCode == 200)
        #expect(provider.callCount == 0)

        var authenticatedRequest = URLRequest(url: credentialURL)
        authenticatedRequest.setValue(token, forHTTPHeaderField: "X-aws-ec2-metadata-token")
        let (_, authenticatedURLResponse) = try await URLSession.shared.data(for: authenticatedRequest)
        let authenticatedResponse = try #require(authenticatedURLResponse as? HTTPURLResponse)
        #expect(authenticatedResponse.statusCode == 200)
        #expect(provider.callCount == 0)
    }

    @MainActor
    @Test func credentialDocumentDoesNotWaitForSlowBackgroundRefresh() async throws {
        let now = Date()
        let initialCredentials = makeCredentials(
            accessKeyId: "ASIACACHEDCREDENTIAL",
            issuedAt: now.addingTimeInterval(-570),
            expiresAt: now.addingTimeInterval(30)
        )
        let provider = StubIMDSCredentialProvider(
            results: [.success(makeCredentials(accessKeyId: "ASIAREFRESHEDCRED"))],
            delay: .seconds(2)
        )
        let server = LocalIMDSServer(
            port: 0,
            servedProfile: servedProfile,
            initialCredentials: initialCredentials,
            credentialProvider: { try await provider.credentials() },
            onRequest: { _ in },
            onFailure: { _ in }
        )
        try await server.start()
        defer { server.stop() }

        await provider.waitUntilCallCount(1)
        var request = URLRequest(url: URL(
            string: "http://127.0.0.1:\(server.boundPort)/latest/meta-data/iam/security-credentials/OrganizationAdmin"
        )!)
        request.timeoutInterval = 0.5

        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        let response = try #require(urlResponse as? HTTPURLResponse)
        #expect(response.statusCode == 200)
        #expect(String(data: data, encoding: .utf8)?.contains("ASIACACHEDCREDENTIAL") == true)
    }

    @MainActor
    @Test func credentialRefreshFailureKeepsUnexpiredCachedCredentialsAvailable() async throws {
        let now = Date()
        let initialCredentials = makeCredentials(
            accessKeyId: "ASIASTILLVALIDCACHE",
            issuedAt: now.addingTimeInterval(-570),
            expiresAt: now.addingTimeInterval(30)
        )
        let provider = StubIMDSCredentialProvider(results: [
            .failure(IAMIdentityCenterError.tokenExpired),
        ])
        var statuses: [Int] = []
        let server = LocalIMDSServer(
            port: 0,
            servedProfile: servedProfile,
            initialCredentials: initialCredentials,
            credentialProvider: { try await provider.credentials() },
            onRequest: { statuses.append($0.status) },
            onFailure: { _ in }
        )
        try await server.start()
        defer { server.stop() }
        let originalPort = server.boundPort
        await provider.waitUntilCallCount(1)
        let url = try #require(URL(
            string: "http://127.0.0.1:\(originalPort)/latest/meta-data/iam/security-credentials/OrganizationAdmin"
        ))

        let (cachedData, cachedURLResponse) = try await URLSession.shared.data(from: url)
        let cachedResponse = try #require(cachedURLResponse as? HTTPURLResponse)
        #expect(cachedResponse.statusCode == 200)
        #expect(String(data: cachedData, encoding: .utf8)?.contains("ASIASTILLVALIDCACHE") == true)
        #expect(server.boundPort == originalPort)
        #expect(provider.callCount == 1)
        #expect(statuses == [200])
    }

    @MainActor
    @Test func localServerBindsConfiguredLoopbackPort() async throws {
        let port = try availableLoopbackPort()
        let server = LocalIMDSServer(
            port: port,
            servedProfile: servedProfile,
            initialCredentials: servedCredentials,
            credentialProvider: { self.servedCredentials },
            onRequest: { _ in },
            onFailure: { _ in }
        )
        try await server.start()
        defer { server.stop() }

        #expect(server.boundPort == port)

        let regionURL = try #require(URL(string: "http://127.0.0.1:\(server.boundPort)/latest/meta-data/placement/region"))
        let (regionData, regionURLResponse) = try await URLSession.shared.data(from: regionURL)
        let regionResponse = try #require(regionURLResponse as? HTTPURLResponse)
        #expect(regionResponse.statusCode == 200)
        #expect(String(data: regionData, encoding: .utf8) == "us-east-2")
    }

    private var servedProfile: IMDSServedProfile {
        IMDSServedProfile(
            profileName: "ac:cp:org_admin",
            sessionName: "astrocompute",
            accountId: "699475923216",
            roleName: "OrganizationAdmin",
            region: "us-east-2"
        )
    }

    private var servedCredentials: RoleCredentials {
        makeCredentials(accessKeyId: "ASIA00000000EXMPL")
    }

    private func makeCredentials(
        accessKeyId: String,
        issuedAt: Date = Date(),
        expiresAt: Date? = nil
    ) -> RoleCredentials {
        RoleCredentials(
            accessKeyId: accessKeyId,
            secretAccessKey: "secret",
            sessionToken: "session-token",
            expiresAt: expiresAt ?? issuedAt.addingTimeInterval(3_600),
            accountId: "699475923216",
            roleName: "OrganizationAdmin",
            region: "us-east-2",
            sessionName: "astrocompute",
            issuedAt: issuedAt
        )
    }

    private func request(
        _ method: String,
        _ path: String,
        headers: [String: String] = [:]
    ) -> IMDSHTTPRequest {
        IMDSHTTPRequest(method: method, path: path, headers: headers)
    }

    private func availableLoopbackPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        var reuse = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(descriptor, sockaddrPointer, &length)
            }
        }
        guard nameResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        return Int(in_port_t(bigEndian: boundAddress.sin_port))
    }
}

@MainActor
private final class StubIMDSCredentialProvider {
    private var results: [Result<RoleCredentials, Error>]
    private let delay: Duration?
    private(set) var callCount = 0

    init(results: [Result<RoleCredentials, Error>], delay: Duration? = nil) {
        self.results = results
        self.delay = delay
    }

    func credentials() async throws -> RoleCredentials {
        callCount += 1
        if let delay {
            try await Task.sleep(for: delay)
        }
        guard !results.isEmpty else {
            throw IAMIdentityCenterError.tokenExpired
        }
        return try results.removeFirst().get()
    }

    func waitUntilCallCount(_ expectedCount: Int) async {
        while callCount < expectedCount {
            await Task.yield()
        }
    }
}
