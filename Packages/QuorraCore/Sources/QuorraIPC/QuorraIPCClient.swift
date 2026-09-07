import Darwin
import Foundation

public final class QuorraIPCClient: @unchecked Sendable {
    private let endpoint: QuorraIPCEndpoint?
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 2, endpoint: QuorraIPCEndpoint? = nil) {
        self.timeout = timeout
        self.endpoint = endpoint
    }

    public func send(_ request: QuorraIPCRequest) throws -> QuorraIPCResponse {
        let resolvedEndpoint = try endpoint ?? .shared()
        let descriptor = try QuorraIPCTransport.makeSocket()
        defer { Darwin.close(descriptor) }

        do {
            try QuorraIPCTransport.configureTimeout(timeout, for: descriptor)
            try QuorraIPCTransport.connect(descriptor, to: resolvedEndpoint.socketURL)
            let requestData = try QuorraIPCCodec.encode(request)
            try QuorraIPCTransport.writeFrame(requestData, to: descriptor)
            let responseData = try QuorraIPCTransport.readFrame(from: descriptor)
            let response = try QuorraIPCCodec.decode(QuorraIPCResponse.self, from: responseData)
            guard response.requestID == request.requestID else {
                throw QuorraIPCClientError.mismatchedResponse
            }
            return response
        } catch let error as QuorraIPCClientError {
            throw error
        } catch let error as QuorraIPCTransportError {
            switch error.errorCode {
            case ENOENT, ECONNREFUSED:
                throw QuorraIPCClientError.appNotRunning
            case EAGAIN, EWOULDBLOCK, ETIMEDOUT:
                throw QuorraIPCClientError.requestTimedOut
            default:
                if error == .connectionClosed {
                    throw QuorraIPCClientError.connectionInvalidated
                }
                throw QuorraIPCClientError.connectionFailed(error.errorCode ?? EIO)
            }
        } catch is QuorraIPCEndpointError {
            throw QuorraIPCClientError.sharedContainerUnavailable
        } catch {
            throw QuorraIPCClientError.invalidResponse
        }
    }
}

public enum QuorraIPCClientError: LocalizedError, Equatable {
    case appNotRunning
    case connectionFailed(Int32)
    case connectionInvalidated
    case invalidResponse
    case requestTimedOut
    case mismatchedResponse
    case sharedContainerUnavailable

    public var errorDescription: String? {
        switch self {
        case .appNotRunning:
            return "Quorra is not running."
        case let .connectionFailed(code):
            return "The connection to Quorra failed: \(String(cString: strerror(code)))."
        case .connectionInvalidated:
            return "The connection to Quorra ended before the command completed."
        case .invalidResponse:
            return "Quorra returned a response that the command-line tool could not read."
        case .requestTimedOut:
            return "Quorra did not respond to the command in time."
        case .mismatchedResponse:
            return "Quorra returned a response for a different command."
        case .sharedContainerUnavailable:
            return "Quorra’s shared command-line container is unavailable. Reinstall Quorra and its command-line tool."
        }
    }
}
