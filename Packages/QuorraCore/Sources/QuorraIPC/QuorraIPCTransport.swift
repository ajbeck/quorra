import Darwin
import Foundation

enum QuorraIPCTransport {
    static let maximumFrameSize = 1_048_576

    static func makeSocket() throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw QuorraIPCTransportError.systemCall("socket", errno)
        }

        do {
            try configureNoSIGPIPE(for: descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    static func configureNoSIGPIPE(for descriptor: Int32) throws {
        var enabled: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout.size(ofValue: enabled))
        ) == 0 else {
            throw QuorraIPCTransportError.systemCall("setsockopt", errno)
        }
    }

    static func address(for socketURL: URL) throws -> sockaddr_un {
        let path = socketURL.path
        let pathBytes = Array(path.utf8CString)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            throw QuorraIPCTransportError.socketPathTooLong(path)
        }

        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                pathBytes.withUnsafeBufferPointer { source in
                    guard let baseAddress = source.baseAddress else { return }
                    destination.update(from: baseAddress, count: pathBytes.count)
                }
            }
        }
        return address
    }

    static func connect(_ descriptor: Int32, to socketURL: URL) throws {
        var address = try address(for: socketURL)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0 else {
            throw QuorraIPCTransportError.systemCall("connect", errno)
        }
    }

    static func configureTimeout(_ timeout: TimeInterval, for descriptor: Int32) throws {
        let clampedTimeout = max(0.001, timeout)
        var value = timeval(
            tv_sec: Int(clampedTimeout),
            tv_usec: Int32((clampedTimeout.truncatingRemainder(dividingBy: 1)) * 1_000_000)
        )
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                option,
                &value,
                socklen_t(MemoryLayout.size(ofValue: value))
            ) == 0 else {
                throw QuorraIPCTransportError.systemCall("setsockopt", errno)
            }
        }
    }

    static func writeFrame(_ data: Data, to descriptor: Int32) throws {
        guard data.count <= maximumFrameSize else {
            throw QuorraIPCTransportError.frameTooLarge(data.count)
        }

        var length = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &length) { bytes in
            try writeAll(bytes, to: descriptor)
        }
        try data.withUnsafeBytes { bytes in
            try writeAll(bytes, to: descriptor)
        }
    }

    static func readFrame(from descriptor: Int32) throws -> Data {
        var length = UInt32.zero
        try withUnsafeMutableBytes(of: &length) { bytes in
            try readAll(bytes, from: descriptor)
        }

        let frameSize = Int(UInt32(bigEndian: length))
        guard frameSize <= maximumFrameSize else {
            throw QuorraIPCTransportError.frameTooLarge(frameSize)
        }

        var data = Data(count: frameSize)
        try data.withUnsafeMutableBytes { bytes in
            try readAll(bytes, from: descriptor)
        }
        return data
    }

    private static func writeAll(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            guard let baseAddress = bytes.baseAddress else { return }
            let result = Darwin.write(
                descriptor,
                baseAddress.advanced(by: offset),
                bytes.count - offset
            )
            if result > 0 {
                offset += result
            } else if result < 0, errno == EINTR {
                continue
            } else {
                throw QuorraIPCTransportError.systemCall("write", result == 0 ? EPIPE : errno)
            }
        }
    }

    private static func readAll(_ bytes: UnsafeMutableRawBufferPointer, from descriptor: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            guard let baseAddress = bytes.baseAddress else { return }
            let result = Darwin.read(
                descriptor,
                baseAddress.advanced(by: offset),
                bytes.count - offset
            )
            if result > 0 {
                offset += result
            } else if result < 0, errno == EINTR {
                continue
            } else if result == 0 {
                throw QuorraIPCTransportError.connectionClosed
            } else {
                throw QuorraIPCTransportError.systemCall("read", errno)
            }
        }
    }
}

enum QuorraIPCTransportError: Error, Equatable {
    case connectionClosed
    case frameTooLarge(Int)
    case socketPathTooLong(String)
    case systemCall(String, Int32)

    var errorCode: Int32? {
        guard case let .systemCall(_, code) = self else { return nil }
        return code
    }
}
