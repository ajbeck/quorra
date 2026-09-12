import Darwin
import Foundation
import Testing
@testable import QuorraIMDSHelperCore

@Suite("IMDS TCP relay")
@MainActor
struct IMDSTCPRelayTests {
    @Test func relaysBytesWithoutInspectingHTTP() async throws {
        let backend = try POSIXEchoBackend()
        defer { backend.stop() }
        let relay = IMDSTCPRelay(
            publicAddress: "127.0.0.1",
            publicPort: 0,
            backendAddress: "127.0.0.1",
            backendPort: backend.port,
            maximumConnections: 4
        )
        try await relay.start()
        defer { relay.stop() }

        let request = Data(
            "PUT /latest/api/token HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8
        )
        let response = try await POSIXClient.roundTrip(request, port: relay.boundPort)

        #expect(response == request)
    }

    @Test func rejectsInvalidConfigurationBeforeListening() async throws {
        let relay = IMDSTCPRelay(publicAddress: "invalid", publicPort: 80)

        await #expect(throws: IMDSTCPRelayError.self) {
            try await relay.start()
        }
    }
}

private enum POSIXSocketError: Error {
    case systemCall(String, POSIXError)
    case timedOut
}

private final class POSIXEchoBackend: @unchecked Sendable {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "dev.ajbeck.quorra.tests.echo-backend")
    private let lock = NSLock()
    private var clientDescriptor: Int32 = -1
    private(set) var port = 0

    init() throws {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw Self.socketError("socket")
        }

        do {
            var reuseAddress: Int32 = 1
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                &reuseAddress,
                socklen_t(MemoryLayout.size(ofValue: reuseAddress))
            ) == 0 else {
                throw Self.socketError("setsockopt")
            }

            var address = Self.loopbackAddress(port: 0)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
            guard bindResult == 0 else {
                throw Self.socketError("bind")
            }
            guard listen(descriptor, 1) == 0 else {
                throw Self.socketError("listen")
            }

            var boundAddress = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &length)
                }
            }
            guard nameResult == 0 else {
                throw Self.socketError("getsockname")
            }
            port = Int(in_port_t(bigEndian: boundAddress.sin_port))
        } catch {
            Darwin.close(descriptor)
            throw error
        }

        queue.async { [weak self] in
            self?.serveOneConnection()
        }
    }

    func stop() {
        lock.withLock {
            if clientDescriptor >= 0 {
                Darwin.shutdown(clientDescriptor, SHUT_RDWR)
                Darwin.close(clientDescriptor)
                clientDescriptor = -1
            }
        }
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private func serveOneConnection() {
        let acceptedDescriptor = accept(descriptor, nil, nil)
        guard acceptedDescriptor >= 0 else { return }
        lock.withLock {
            clientDescriptor = acceptedDescriptor
        }

        defer {
            lock.withLock {
                if clientDescriptor == acceptedDescriptor {
                    Darwin.close(acceptedDescriptor)
                    clientDescriptor = -1
                }
            }
        }

        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(acceptedDescriptor, &buffer, buffer.count)
        guard count > 0 else { return }
        guard (try? Self.writeAll(
            Data(buffer.prefix(count)),
            to: acceptedDescriptor
        )) != nil else { return }
        Darwin.shutdown(acceptedDescriptor, SHUT_WR)
    }

    fileprivate static func loopbackAddress(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return address
    }

    fileprivate static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    start.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else {
                    throw socketError("write")
                }
                offset += count
            }
        }
    }

    fileprivate static func socketError(_ call: String) -> POSIXSocketError {
        POSIXSocketError.systemCall(
            call,
            POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        )
    }
}

private enum POSIXClient {
    static func roundTrip(_ request: Data, port: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try roundTripSync(request, port: port))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func roundTripSync(_ request: Data, port: Int) throws -> Data {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXEchoBackend.socketError("socket")
        }
        defer { Darwin.close(descriptor) }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        ) == 0 else {
            throw POSIXEchoBackend.socketError("setsockopt")
        }

        var address = POSIXEchoBackend.loopbackAddress(port: port)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard connectResult == 0 else {
            throw POSIXEchoBackend.socketError("connect")
        }

        try POSIXEchoBackend.writeAll(request, to: descriptor)
        Darwin.shutdown(descriptor, SHUT_WR)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 {
                return response
            }
            guard count > 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw POSIXSocketError.timedOut
                }
                throw POSIXEchoBackend.socketError("read")
            }
            response.append(buffer, count: count)
        }
    }
}
