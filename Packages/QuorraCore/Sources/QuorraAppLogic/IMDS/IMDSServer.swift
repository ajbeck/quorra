import Foundation
import IAMIdentityCenter
import Network

public struct IMDSServedProfile: Hashable, Sendable {
    public let profileName: String
    public let sessionName: String
    public let accountId: String
    public let roleName: String
    public let region: String

    public init(
        profileName: String,
        sessionName: String,
        accountId: String,
        roleName: String,
        region: String
    ) {
        self.profileName = profileName
        self.sessionName = sessionName
        self.accountId = accountId
        self.roleName = roleName
        self.region = region
    }
}

public struct IMDSRequestLog: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let method: String
    public let path: String
    public let client: String
    public let status: Int

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        method: String,
        path: String,
        client: String,
        status: Int
    ) {
        self.id = id
        self.timestamp = timestamp
        self.method = method
        self.path = path
        self.client = client
        self.status = status
    }
}

public struct IMDSRuntimeInfo: Hashable, Sendable {
    public let startedAt: Date
    public let servedProfileName: String
    public var requestCount: Int
    public var activity: [IMDSRequestLog]

    public init(startedAt: Date = Date(), servedProfileName: String) {
        self.startedAt = startedAt
        self.servedProfileName = servedProfileName
        self.requestCount = 0
        self.activity = []
    }
}

struct IMDSHTTPRequest: Hashable, Sendable {
    let method: String
    let path: String
    let headers: [String: String]

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    static func parse(_ data: Data) -> IMDSHTTPRequest? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let head = normalized.components(separatedBy: "\n\n").first else { return nil }
        var lines = head.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                headers[key] = value
            }
        }

        return IMDSHTTPRequest(
            method: requestLine[0].uppercased(),
            path: normalizeTarget(requestLine[1]),
            headers: headers
        )
    }

    private static func normalizeTarget(_ rawTarget: String) -> String {
        let path: String
        if rawTarget.hasPrefix("http://") || rawTarget.hasPrefix("https://"),
           let url = URL(string: rawTarget) {
            path = url.path(percentEncoded: false)
        } else {
            path = String(rawTarget.split(separator: "?", maxSplits: 1).first ?? Substring(rawTarget))
        }

        guard path.hasPrefix("/") else { return "/" + path }
        return path
    }
}

struct IMDSHTTPResponse: Hashable, Sendable {
    let statusCode: Int
    let reasonPhrase: String
    var headers: [String: String]
    let body: Data

    init(
        statusCode: Int,
        reasonPhrase: String,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
        self.body = body
    }

    static func text(_ text: String, statusCode: Int = 200, reasonPhrase: String = "OK") -> IMDSHTTPResponse {
        IMDSHTTPResponse(
            statusCode: statusCode,
            reasonPhrase: reasonPhrase,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(text.utf8)
        )
    }

    static func json(_ data: Data, statusCode: Int = 200, reasonPhrase: String = "OK") -> IMDSHTTPResponse {
        IMDSHTTPResponse(
            statusCode: statusCode,
            reasonPhrase: reasonPhrase,
            headers: ["Content-Type": "application/json"],
            body: data
        )
    }

    static func status(_ statusCode: Int, _ reasonPhrase: String, message: String? = nil) -> IMDSHTTPResponse {
        if let message {
            return .text(message, statusCode: statusCode, reasonPhrase: reasonPhrase)
        }
        return IMDSHTTPResponse(statusCode: statusCode, reasonPhrase: reasonPhrase)
    }

    func data() -> Data {
        var lines = [
            "HTTP/1.1 \(statusCode) \(reasonPhrase)",
            "Content-Length: \(body.count)",
            "Connection: close"
        ]

        for key in headers.keys.sorted() {
            if let value = headers[key] {
                lines.append("\(key): \(value)")
            }
        }

        lines.append("")
        lines.append("")

        var response = Data(lines.joined(separator: "\r\n").utf8)
        response.append(body)
        return response
    }
}

enum IMDSRoutingResult: Sendable {
    case response(IMDSHTTPResponse)
    case credentialDocument
}

struct IMDSRouter: Sendable {
    var servedProfile: IMDSServedProfile
    var allowsIMDSv1: Bool
    private var tokens: [String: Date] = [:]
    private let startedAt: Date

    init(
        servedProfile: IMDSServedProfile,
        allowsIMDSv1: Bool = true,
        startedAt: Date = Date()
    ) {
        self.servedProfile = servedProfile
        self.allowsIMDSv1 = allowsIMDSv1
        self.startedAt = startedAt
    }

    mutating func response(for request: IMDSHTTPRequest, now: Date = Date()) -> IMDSHTTPResponse {
        switch route(for: request, now: now) {
        case .response(let response):
            return response
        case .credentialDocument:
            return .status(503, "Service Unavailable", message: "Credentials unavailable.")
        }
    }

    mutating func route(for request: IMDSHTTPRequest, now: Date = Date()) -> IMDSRoutingResult {
        if request.path == "/latest/api/token" {
            return .response(tokenResponse(for: request, now: now))
        }

        guard request.method == "GET" else {
            return .response(.status(405, "Method Not Allowed"))
        }

        if let token = request.header("x-aws-ec2-metadata-token") {
            guard isValidToken(token, now: now) else {
                return .response(.status(401, "Unauthorized", message: "Invalid or expired IMDSv2 token.\n"))
            }
        } else if !allowsIMDSv1 {
            return .response(.status(401, "Unauthorized", message: "IMDSv2 token required.\n"))
        }

        switch normalizedComponents(for: request.path) {
        case ["latest"]:
            return .response(.text("meta-data/\ndynamic/"))
        case ["latest", "meta-data"]:
            return .response(.text("iam/\nplacement/\nservices/"))
        case ["latest", "meta-data", "iam"]:
            return .response(.text("security-credentials/"))
        case ["latest", "meta-data", "iam", "security-credentials"]:
            return .response(.text(servedProfile.roleName))
        case ["latest", "meta-data", "iam", "security-credentials", servedProfile.roleName]:
            return .credentialDocument
        case ["latest", "meta-data", "placement"]:
            return .response(.text("availability-zone\nregion"))
        case ["latest", "meta-data", "placement", "region"]:
            return .response(.text(servedProfile.region))
        case ["latest", "meta-data", "placement", "availability-zone"]:
            return .response(.text("\(servedProfile.region)a"))
        case ["latest", "meta-data", "services"]:
            return .response(.text("domain\npartition"))
        case ["latest", "meta-data", "services", "domain"]:
            return .response(.text(serviceDomain(for: servedProfile.region)))
        case ["latest", "meta-data", "services", "partition"]:
            return .response(.text(partition(for: servedProfile.region)))
        case ["latest", "dynamic"]:
            return .response(.text("instance-identity/"))
        case ["latest", "dynamic", "instance-identity"]:
            return .response(.text("document"))
        case ["latest", "dynamic", "instance-identity", "document"]:
            return .response(instanceIdentityDocumentResponse())
        default:
            return .response(.status(404, "Not Found"))
        }
    }

    private mutating func tokenResponse(for request: IMDSHTTPRequest, now: Date) -> IMDSHTTPResponse {
        guard request.method == "PUT" else {
            return .status(405, "Method Not Allowed")
        }

        guard let ttlText = request.header("x-aws-ec2-metadata-token-ttl-seconds"),
              let ttl = TimeInterval(ttlText),
              ttl >= 1,
              ttl <= 21_600 else {
            return .status(400, "Bad Request", message: "X-aws-ec2-metadata-token-ttl-seconds must be 1-21600.\n")
        }

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        tokens[token] = now.addingTimeInterval(ttl)
        return .text(token)
    }

    private func isValidToken(_ token: String, now: Date) -> Bool {
        guard let expiresAt = tokens[token] else { return false }
        return expiresAt > now
    }

    private func normalizedComponents(for path: String) -> [String] {
        path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
    }

    func credentialsResponse(using credentials: RoleCredentials) -> IMDSHTTPResponse {
        struct CredentialsDocument: Encodable {
            let Code: String
            let LastUpdated: String
            let credentialType: String
            let AccessKeyId: String
            let SecretAccessKey: String
            let Token: String
            let Expiration: String

            enum CodingKeys: String, CodingKey {
                case Code
                case LastUpdated
                case credentialType = "Type"
                case AccessKeyId
                case SecretAccessKey
                case Token
                case Expiration
            }
        }

        let document = CredentialsDocument(
            Code: "Success",
            LastUpdated: iso8601(credentials.issuedAt),
            credentialType: "AWS-HMAC",
            AccessKeyId: credentials.accessKeyId,
            SecretAccessKey: credentials.secretAccessKey,
            Token: credentials.sessionToken,
            Expiration: iso8601(credentials.expiresAt)
        )
        return encodeJSON(document)
    }

    private func instanceIdentityDocumentResponse() -> IMDSHTTPResponse {
        struct IdentityDocument: Encodable {
            let accountId: String
            let architecture: String
            let availabilityZone: String
            let imageId: String
            let instanceId: String
            let instanceType: String
            let pendingTime: String
            let privateIp: String
            let region: String
            let version: String
        }

        let document = IdentityDocument(
            accountId: servedProfile.accountId,
            architecture: "arm64",
            availabilityZone: "\(servedProfile.region)a",
            imageId: "ami-quorra-local",
            instanceId: "i-quorra-\(servedProfile.profileName.stableIMDSSuffix)",
            instanceType: "quorra.local",
            pendingTime: iso8601(startedAt),
            privateIp: "127.0.0.1",
            region: servedProfile.region,
            version: "2017-09-30"
        )
        return encodeJSON(document)
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> IMDSHTTPResponse {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return .json(try encoder.encode(value))
        } catch {
            return .status(500, "Internal Server Error")
        }
    }

    private func partition(for region: String) -> String {
        if region.hasPrefix("cn-") { return "aws-cn" }
        if region.hasPrefix("us-gov-") { return "aws-us-gov" }
        return "aws"
    }

    private func serviceDomain(for region: String) -> String {
        partition(for: region) == "aws-cn" ? "amazonaws.com.cn" : "amazonaws.com"
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

@MainActor
public final class LocalIMDSServer {
    public typealias CredentialProvider = @MainActor () async throws -> RoleCredentials

    private static let maximumCredentialRefreshLeadTime: TimeInterval = 5 * 60
    private static let credentialRefreshLeadTimeFraction = 0.10

    private let port: Int
    private var router: IMDSRouter
    private let credentialProvider: CredentialProvider
    private let credentialRefreshRetryDelay: TimeInterval
    private let onRequest: (IMDSRequestLog) -> Void
    private let onFailure: (String) -> Void
    private let queue = DispatchQueue.main
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var cachedCredentials: RoleCredentials
    private var cachedCredentialsResponse: IMDSHTTPResponse
    private var credentialRefreshTimer: Task<Void, Never>?
    private var credentialRefreshInFlight: Task<Void, Never>?
    public private(set) var boundPort: Int

    public init(
        port: Int,
        servedProfile: IMDSServedProfile,
        allowsIMDSv1: Bool = true,
        initialCredentials: RoleCredentials,
        credentialRefreshRetryDelay: TimeInterval = 30,
        credentialProvider: @escaping CredentialProvider,
        onRequest: @escaping (IMDSRequestLog) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        let router = IMDSRouter(servedProfile: servedProfile, allowsIMDSv1: allowsIMDSv1)
        self.port = port
        self.boundPort = port
        self.router = router
        self.cachedCredentials = initialCredentials
        self.cachedCredentialsResponse = router.credentialsResponse(using: initialCredentials)
        self.credentialProvider = credentialProvider
        self.credentialRefreshRetryDelay = credentialRefreshRetryDelay
        self.onRequest = onRequest
        self.onFailure = onFailure
    }

    public func start() async throws {
        guard listener == nil else { return }
        guard let portValue = UInt16(exactly: port),
              let nwPort = NWEndpoint.Port(rawValue: portValue) else {
            throw LocalIMDSServerError.invalidPort(port)
        }

        let parameters = NWParameters.tcp
        let listener: NWListener
        if let loopback = IPv4Address("127.0.0.1") {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(loopback), port: nwPort)
            listener = try NWListener(using: parameters)
        } else {
            listener = try NWListener(using: parameters, on: nwPort)
        }
        self.listener = listener

        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleListenerState(state)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.accept(connection)
                }
            }
            listener.start(queue: queue)
        }

        scheduleCredentialRefresh()
    }

    public func stop() {
        credentialRefreshTimer?.cancel()
        credentialRefreshTimer = nil
        credentialRefreshInFlight?.cancel()
        credentialRefreshInFlight = nil
        startContinuation?.resume(throwing: CancellationError())
        startContinuation = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let rawValue = listener?.port?.rawValue {
                boundPort = Int(rawValue)
            }
            startContinuation?.resume()
            startContinuation = nil
        case .failed(let error):
            let message = LocalIMDSServerError.network(error).localizedDescription
            if let continuation = startContinuation {
                continuation.resume(throwing: LocalIMDSServerError.network(error))
                startContinuation = nil
            } else {
                onFailure(message)
            }
            stop()
        case .cancelled:
            startContinuation?.resume(throwing: CancellationError())
            startContinuation = nil
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self, weak connection] in
                    guard let connection else { return }
                    self?.connections[ObjectIdentifier(connection)] = nil
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak connection] data, _, isComplete, error in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection else { return }
                guard error == nil else {
                    connection.cancel()
                    self.connections[ObjectIdentifier(connection)] = nil
                    return
                }

                var nextBuffer = buffer
                if let data {
                    nextBuffer.append(data)
                }

                if nextBuffer.count > 65_536 {
                    self.send(.status(413, "Payload Too Large"), on: connection, request: nil)
                    return
                }

                if nextBuffer.containsCompleteHTTPHeader {
                    self.handleRequest(nextBuffer, on: connection)
                } else if isComplete {
                    self.send(.status(400, "Bad Request"), on: connection, request: nil)
                } else {
                    self.receive(on: connection, buffer: nextBuffer)
                }
            }
        }
    }

    private func handleRequest(_ data: Data, on connection: NWConnection) {
        guard let request = IMDSHTTPRequest.parse(data) else {
            send(.status(400, "Bad Request"), on: connection, request: nil)
            return
        }

        switch router.route(for: request) {
        case .response(let response):
            send(response, on: connection, request: request)
        case .credentialDocument:
            sendCachedCredentials(on: connection, request: request)
        }
    }

    private func sendCachedCredentials(on connection: NWConnection, request: IMDSHTTPRequest) {
        let now = Date()
        guard now < cachedCredentials.expiresAt else {
            beginCredentialRefresh()
            send(
                .status(503, "Service Unavailable", message: "Credentials unavailable."),
                on: connection,
                request: request
            )
            return
        }

        send(cachedCredentialsResponse, on: connection, request: request)

        if now >= Self.credentialRefreshDeadline(for: cachedCredentials) {
            beginCredentialRefresh()
        }
    }

    private func scheduleCredentialRefresh(after delayOverride: TimeInterval? = nil) {
        credentialRefreshTimer?.cancel()

        let delay = max(
            0,
            delayOverride ?? Self.credentialRefreshDeadline(for: cachedCredentials).timeIntervalSinceNow
        )
        credentialRefreshTimer = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, self.listener != nil else { return }
            self.credentialRefreshTimer = nil
            self.beginCredentialRefresh()
        }
    }

    private func beginCredentialRefresh() {
        guard listener != nil,
              credentialRefreshTimer == nil,
              credentialRefreshInFlight == nil else { return }

        let provider = credentialProvider
        credentialRefreshInFlight = Task { @MainActor [weak self] in
            do {
                let credentials = try await provider()
                guard let self, !Task.isCancelled, self.listener != nil else { return }
                self.cachedCredentials = credentials
                self.cachedCredentialsResponse = self.router.credentialsResponse(using: credentials)
                self.credentialRefreshInFlight = nil
                self.scheduleCredentialRefresh()
            } catch {
                guard let self, !Task.isCancelled, self.listener != nil else { return }
                self.credentialRefreshInFlight = nil
                self.scheduleCredentialRefresh(after: self.credentialRefreshRetryDelay)
            }
        }
    }

    private static func credentialRefreshDeadline(for credentials: RoleCredentials) -> Date {
        let lifetime = max(0, credentials.expiresAt.timeIntervalSince(credentials.issuedAt))
        let leadTime = min(maximumCredentialRefreshLeadTime, lifetime * credentialRefreshLeadTimeFraction)
        return credentials.expiresAt.addingTimeInterval(-leadTime)
    }

    private func send(_ response: IMDSHTTPResponse, on connection: NWConnection, request: IMDSHTTPRequest?) {
        if let request {
            onRequest(IMDSRequestLog(
                method: request.method,
                path: request.path,
                client: request.header("user-agent").map(Self.compactUserAgent) ?? "localhost",
                status: response.statusCode
            ))
        }

        connection.send(content: response.data(), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self, weak connection] _ in
            Task { @MainActor [weak self, weak connection] in
                guard let connection else { return }
                connection.cancel()
                self?.connections[ObjectIdentifier(connection)] = nil
            }
        })
    }

    private static func compactUserAgent(_ userAgent: String) -> String {
        String(userAgent.split(separator: " ").first.map(String.init) ?? userAgent).prefixString(maxLength: 28)
    }
}

enum LocalIMDSServerError: LocalizedError {
    case invalidPort(Int)
    case network(NWError)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "Port \(port) is not valid."
        case .network(let error):
            if case .posix(let code) = error, code == .EADDRINUSE {
                return "Port is already in use."
            }
            return error.localizedDescription
        }
    }
}

private extension Data {
    var containsCompleteHTTPHeader: Bool {
        range(of: Data("\r\n\r\n".utf8)) != nil || range(of: Data("\n\n".utf8)) != nil
    }
}

private extension String {
    var stableIMDSSuffix: String {
        let scalars = unicodeScalars.reduce(into: UInt64(14_695_981_039_346_656_037)) { hash, scalar in
            hash ^= UInt64(scalar.value)
            hash = hash &* 1_099_511_628_211
        }
        return String(scalars, radix: 16)
    }

    func prefixString(maxLength: Int) -> String {
        guard count > maxLength else { return self }
        return String(prefix(maxLength))
    }
}
