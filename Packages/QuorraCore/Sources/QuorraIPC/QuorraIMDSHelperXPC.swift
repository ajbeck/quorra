import Foundation

public enum QuorraIMDSHelperXPC {
    public static let machServiceName = "9GEBAJV9R4.quorra.imds-helper"
    public static let helperIdentifier = "dev.ajbeck.quorra.imds-helper"

    public static let appCodeSigningRequirement = codeSigningRequirement(
        identifier: QuorraIPCProtocol.appIdentifier
    )
    public static let helperCodeSigningRequirement = codeSigningRequirement(
        identifier: helperIdentifier
    )

    public static func makePrivilegedConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: QuorraIMDSHelperXPCProtocol.self
        )
        connection.setCodeSigningRequirement(helperCodeSigningRequirement)
        return connection
    }

    private static func codeSigningRequirement(identifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" "
            + "and certificate leaf[subject.OU] = \"\(QuorraIPCProtocol.teamIdentifier)\""
    }
}

public enum QuorraIMDSHelperState: String, Codable, CaseIterable, Sendable {
    case disabled
    case enabling
    case enabled
    case disabling
    case failed
}

public struct QuorraIMDSHelperStatus: Equatable, Sendable {
    public let state: QuorraIMDSHelperState
    public let failureMessage: String?

    public init(state: QuorraIMDSHelperState, failureMessage: String? = nil) {
        self.state = state
        self.failureMessage = failureMessage
    }
}

@objc(QuorraIMDSHelperXPCProtocol)
public protocol QuorraIMDSHelperXPCProtocol: AnyObject {
    func status(reply: @escaping (String, String?) -> Void)
    func enable(reply: @escaping (String, String?) -> Void)
    func disable(reply: @escaping (String, String?) -> Void)
}

public enum QuorraIMDSHelperClientError: LocalizedError, Equatable {
    case invalidRemoteObject
    case invalidState(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRemoteObject:
            return "The metadata endpoint helper did not expose its control interface."
        case .invalidState(let state):
            return "The metadata endpoint helper returned an unknown state: \(state)."
        }
    }
}

public final class QuorraIMDSHelperClient: @unchecked Sendable {
    private let connectionFactory: @Sendable () -> NSXPCConnection

    public convenience init() {
        self.init(connectionFactory: QuorraIMDSHelperXPC.makePrivilegedConnection)
    }

    init(connectionFactory: @escaping @Sendable () -> NSXPCConnection) {
        self.connectionFactory = connectionFactory
    }

    public func status() async throws -> QuorraIMDSHelperStatus {
        try await request { proxy, reply in
            proxy.status(reply: reply)
        }
    }

    public func enable() async throws -> QuorraIMDSHelperStatus {
        try await request { proxy, reply in
            proxy.enable(reply: reply)
        }
    }

    public func disable() async throws -> QuorraIMDSHelperStatus {
        try await request { proxy, reply in
            proxy.disable(reply: reply)
        }
    }

    private func request(
        _ operation: @escaping @Sendable (
            QuorraIMDSHelperXPCProtocol,
            @escaping (String, String?) -> Void
        ) -> Void
    ) async throws -> QuorraIMDSHelperStatus {
        let connection = connectionFactory()
        return try await withCheckedThrowingContinuation { continuation in
            let reply = XPCContinuation(continuation: continuation, connection: connection)
            connection.interruptionHandler = {
                reply.fail(NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSXPCConnectionInterrupted
                ))
            }
            connection.invalidationHandler = {
                reply.fail(NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSXPCConnectionInvalid
                ))
            }
            connection.activate()

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                reply.fail(error)
            }) as? QuorraIMDSHelperXPCProtocol else {
                reply.fail(QuorraIMDSHelperClientError.invalidRemoteObject)
                return
            }

            operation(proxy) { state, failureMessage in
                guard let state = QuorraIMDSHelperState(rawValue: state) else {
                    reply.fail(QuorraIMDSHelperClientError.invalidState(state))
                    return
                }
                reply.succeed(QuorraIMDSHelperStatus(
                    state: state,
                    failureMessage: failureMessage
                ))
            }
        }
    }
}

private final class XPCContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<QuorraIMDSHelperStatus, Error>?
    private var connection: NSXPCConnection?

    init(
        continuation: CheckedContinuation<QuorraIMDSHelperStatus, Error>,
        connection: NSXPCConnection
    ) {
        self.continuation = continuation
        self.connection = connection
    }

    func succeed(_ status: QuorraIMDSHelperStatus) {
        complete(with: .success(status))
    }

    func fail(_ error: Error) {
        complete(with: .failure(error))
    }

    private func complete(with result: Result<QuorraIMDSHelperStatus, Error>) {
        let completion = lock.withLock { () -> (
            CheckedContinuation<QuorraIMDSHelperStatus, Error>,
            NSXPCConnection
        )? in
            guard let continuation, let connection else { return nil }
            self.continuation = nil
            self.connection = nil
            return (continuation, connection)
        }
        guard let (continuation, connection) = completion else { return }
        continuation.resume(with: result)
        connection.invalidate()
    }
}
