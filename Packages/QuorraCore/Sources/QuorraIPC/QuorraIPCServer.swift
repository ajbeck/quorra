import Darwin
import Dispatch
import Foundation
import OSLog

private let ipcServerLogger = Logger(subsystem: "dev.ajbeck.quorra", category: "IPC.Server")

public final class QuorraIPCServer: @unchecked Sendable {
    public typealias RequestHandler = @Sendable (QuorraIPCRequest) async -> QuorraIPCResponse

    private let endpoint: QuorraIPCEndpoint?
    private let requestTimeout: TimeInterval
    private let handler: RequestHandler
    private let queue = DispatchQueue(label: "dev.ajbeck.quorra.ipc.server", qos: .userInitiated)
    private let connectionQueue = DispatchQueue(
        label: "dev.ajbeck.quorra.ipc.connections",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let stateLock = NSLock()
    private var source: DispatchSourceRead?
    private var socketURL: URL?

    public init(
        endpoint: QuorraIPCEndpoint? = nil,
        requestTimeout: TimeInterval = 10,
        handler: @escaping RequestHandler
    ) {
        self.endpoint = endpoint
        self.requestTimeout = requestTimeout
        self.handler = handler
    }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard source == nil else { return }

        let resolvedEndpoint = try endpoint ?? .shared()
        let descriptor = try makeListener(at: resolvedEndpoint.socketURL)
        let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        readSource.setEventHandler { [weak self] in
            self?.acceptConnection(from: descriptor)
        }
        readSource.setCancelHandler {
            Darwin.close(descriptor)
        }
        socketURL = resolvedEndpoint.socketURL
        source = readSource
        readSource.resume()
    }

    public func stop() {
        stateLock.lock()
        let source = self.source
        let socketURL = self.socketURL
        self.source = nil
        self.socketURL = nil
        stateLock.unlock()

        source?.cancel()
        if let socketURL {
            unlink(socketURL.path)
        }
    }

    private func makeListener(at socketURL: URL) throws -> Int32 {
        try removeStaleSocketIfNeeded(at: socketURL)
        let descriptor = try QuorraIPCTransport.makeSocket()

        do {
            var address = try QuorraIPCTransport.address(for: socketURL)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard bindResult == 0 else {
                throw QuorraIPCServerError.systemCall("bind", errno)
            }
            guard chmod(socketURL.path, S_IRUSR | S_IWUSR) == 0 else {
                throw QuorraIPCServerError.systemCall("chmod", errno)
            }
            guard Darwin.listen(descriptor, SOMAXCONN) == 0 else {
                throw QuorraIPCServerError.systemCall("listen", errno)
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            unlink(socketURL.path)
            throw error
        }
    }

    private func removeStaleSocketIfNeeded(at socketURL: URL) throws {
        var metadata = stat()
        guard lstat(socketURL.path, &metadata) == 0 else {
            if errno == ENOENT { return }
            throw QuorraIPCServerError.systemCall("lstat", errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFSOCK else {
            throw QuorraIPCServerError.endpointOccupied
        }

        let probe = try QuorraIPCTransport.makeSocket()
        defer { Darwin.close(probe) }
        do {
            try QuorraIPCTransport.connect(probe, to: socketURL)
            throw QuorraIPCServerError.alreadyRunning
        } catch let error as QuorraIPCTransportError {
            guard error.errorCode == ECONNREFUSED || error.errorCode == ENOENT else {
                throw QuorraIPCServerError.endpointOccupied
            }
        }

        guard unlink(socketURL.path) == 0 || errno == ENOENT else {
            throw QuorraIPCServerError.systemCall("unlink", errno)
        }
    }

    private func acceptConnection(from listener: Int32) {
        let descriptor = Darwin.accept(listener, nil, nil)
        guard descriptor >= 0 else {
            ipcServerLogger.error("Unable to accept CLI connection: \(errno)")
            return
        }

        connectionQueue.async { [weak self] in
            guard let self else {
                Darwin.close(descriptor)
                return
            }
            self.processConnection(descriptor)
        }
    }

    private func processConnection(_ descriptor: Int32) {
        do {
            try QuorraIPCTransport.configureNoSIGPIPE(for: descriptor)
            try authorizePeer(descriptor)
            try QuorraIPCTransport.configureTimeout(requestTimeout, for: descriptor)
            let requestData = try QuorraIPCTransport.readFrame(from: descriptor)
            let request = try QuorraIPCCodec.decode(QuorraIPCRequest.self, from: requestData)

            Task { [handler] in
                let response: QuorraIPCResponse
                if request.protocolVersion < QuorraIPCProtocol.minimumSupportedVersion
                    || request.protocolVersion > QuorraIPCProtocol.currentVersion {
                    response = .failure(
                        requestID: request.requestID,
                        code: .incompatibleProtocol,
                        message: "Update Quorra and its command-line tool so their versions match."
                    )
                } else {
                    response = await handler(request)
                }

                do {
                    let responseData = try QuorraIPCCodec.encode(response)
                    try QuorraIPCTransport.writeFrame(responseData, to: descriptor)
                } catch {
                    ipcServerLogger.error(
                        "Unable to return CLI response: \(String(describing: error), privacy: .public)"
                    )
                }
                Darwin.close(descriptor)
            }
        } catch {
            ipcServerLogger.error(
                "Rejected CLI request: \(String(describing: error), privacy: .public)"
            )
            let response = QuorraIPCResponse.failure(
                requestID: UUID(),
                code: .invalidRequest,
                message: "Quorra could not decode the command request."
            )
            do {
                let responseData = try QuorraIPCCodec.encode(response)
                try QuorraIPCTransport.writeFrame(responseData, to: descriptor)
            } catch {
                ipcServerLogger.error(
                    "Unable to return CLI rejection: \(String(describing: error), privacy: .public)"
                )
            }
            Darwin.close(descriptor)
        }
    }

    private func authorizePeer(_ descriptor: Int32) throws {
        var peerUserID = uid_t()
        var peerGroupID = gid_t()
        guard getpeereid(descriptor, &peerUserID, &peerGroupID) == 0 else {
            throw QuorraIPCServerError.systemCall("getpeereid", errno)
        }
        guard peerUserID == geteuid() else {
            throw QuorraIPCServerError.unauthorizedPeer
        }
    }

    deinit {
        stop()
    }
}

public enum QuorraIPCServerError: LocalizedError, Equatable {
    case alreadyRunning
    case endpointOccupied
    case unauthorizedPeer
    case systemCall(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Another Quorra process is already serving command-line requests."
        case .endpointOccupied:
            return "Quorra’s command-line socket path is occupied by another file."
        case .unauthorizedPeer:
            return "The command-line request came from another user account."
        case let .systemCall(operation, code):
            return "Quorra IPC failed during \(operation): \(String(cString: strerror(code)))."
        }
    }
}
