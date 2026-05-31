import Foundation
import IAMIdentityCenter
import Network

struct IMDSServedProfile: Hashable, Sendable {
    let profileName: String
    let sessionName: String
    let accountId: String
    let roleName: String
    let region: String
    let credentials: RoleCredentials
}

struct IMDSRequestLog: Identifiable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let method: String
    let path: String
    let client: String
    let status: Int

    init(
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

struct IMDSRuntimeInfo: Hashable, Sendable {
    let startedAt: Date
    let servedProfileName: String
    var requestCount: Int
    var activity: [IMDSRequestLog]

    init(startedAt: Date = Date(), servedProfileName: String) {
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

struct IMDSRouter: Sendable {
    var servedProfile: IMDSServedProfile
    var allowsIMDSv1: Bool
    private var tokens: [String: Date] = [:]

    init(servedProfile: IMDSServedProfile, allowsIMDSv1: Bool = true) {
        self.servedProfile = servedProfile
        self.allowsIMDSv1 = allowsIMDSv1
    }

    mutating func response(for request: IMDSHTTPRequest, now: Date = Date()) -> IMDSHTTPResponse {
        if request.path == "/latest/api/token" {
            return tokenResponse(for: request, now: now)
        }

        guard request.method == "GET" else {
            return .status(405, "Method Not Allowed")
        }

        if let token = request.header("x-aws-ec2-metadata-token") {
            guard isValidToken(token, now: now) else {
                return .status(401, "Unauthorized", message: "Invalid or expired IMDSv2 token.\n")
            }
        } else if !allowsIMDSv1 {
            return .status(401, "Unauthorized", message: "IMDSv2 token required.\n")
        }

        switch normalizedComponents(for: request.path) {
        case ["latest"]:
            return .text("meta-data/\ndynamic/\n")
        case ["latest", "meta-data"]:
            return .text("iam/\nplacement/\nservices/\n")
        case ["latest", "meta-data", "iam"]:
            return .text("security-credentials/\n")
        case ["latest", "meta-data", "iam", "security-credentials"]:
            return .text("\(servedProfile.roleName)\n")
        case ["latest", "meta-data", "iam", "security-credentials", servedProfile.roleName]:
            return credentialsResponse()
        case ["latest", "meta-data", "placement"]:
            return .text("availability-zone\nregion\n")
        case ["latest", "meta-data", "placement", "region"]:
            return .text("\(servedProfile.region)\n")
        case ["latest", "meta-data", "placement", "availability-zone"]:
            return .text("\(servedProfile.region)a\n")
        case ["latest", "meta-data", "services"]:
            return .text("domain\npartition\n")
        case ["latest", "meta-data", "services", "domain"]:
            return .text("\(serviceDomain(for: servedProfile.region))\n")
        case ["latest", "meta-data", "services", "partition"]:
            return .text("\(partition(for: servedProfile.region))\n")
        case ["latest", "dynamic"]:
            return .text("instance-identity/\n")
        case ["latest", "dynamic", "instance-identity"]:
            return .text("document\n")
        case ["latest", "dynamic", "instance-identity", "document"]:
            return instanceIdentityDocumentResponse()
        default:
            return .status(404, "Not Found")
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

    private func credentialsResponse() -> IMDSHTTPResponse {
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
            LastUpdated: iso8601(servedProfile.credentials.issuedAt),
            credentialType: "AWS-HMAC",
            AccessKeyId: servedProfile.credentials.accessKeyId,
            SecretAccessKey: servedProfile.credentials.secretAccessKey,
            Token: servedProfile.credentials.sessionToken,
            Expiration: iso8601(servedProfile.credentials.expiresAt)
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
            pendingTime: iso8601(servedProfile.credentials.issuedAt),
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
final class LocalIMDSServer {
    private let port: Int
    private var router: IMDSRouter
    private let onRequest: (IMDSRequestLog) -> Void
    private let onFailure: (String) -> Void
    private let queue = DispatchQueue.main
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var startContinuation: CheckedContinuation<Void, Error>?
    private(set) var boundPort: Int

    init(
        port: Int,
        servedProfile: IMDSServedProfile,
        allowsIMDSv1: Bool = true,
        onRequest: @escaping (IMDSRequestLog) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        self.port = port
        self.boundPort = port
        self.router = IMDSRouter(servedProfile: servedProfile, allowsIMDSv1: allowsIMDSv1)
        self.onRequest = onRequest
        self.onFailure = onFailure
    }

    func start() async throws {
        guard listener == nil else { return }
        guard let portValue = UInt16(exactly: port),
              let nwPort = NWEndpoint.Port(rawValue: portValue) else {
            throw LocalIMDSServerError.invalidPort(port)
        }

        let parameters = NWParameters.tcp
        if let loopback = IPv4Address("127.0.0.1") {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(loopback), port: nwPort)
        }

        let listener = try NWListener(using: parameters, on: nwPort)
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
    }

    func stop() {
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

        let response = router.response(for: request)
        send(response, on: connection, request: request)
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
