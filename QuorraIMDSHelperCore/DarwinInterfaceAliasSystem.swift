import Darwin
import Foundation

protocol SystemCommandRunning {
    func run(executableURL: URL, arguments: [String]) throws
}

enum SystemCommandError: LocalizedError, Equatable {
    case failed(executable: String, status: Int32, standardError: String)

    var errorDescription: String? {
        switch self {
        case .failed(let executable, let status, let standardError):
            let detail = standardError.isEmpty ? "No error output was produced." : standardError
            return "\(executable) exited with status \(status): \(detail)"
        }
    }
}

struct FoundationSystemCommandRunner: SystemCommandRunning {
    func run(executableURL: URL, arguments: [String]) throws {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let data = standardError.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SystemCommandError.failed(
                executable: executableURL.path,
                status: process.terminationStatus,
                standardError: message
            )
        }
    }
}

public enum DarwinInterfaceAliasSystemError: LocalizedError, Equatable {
    case invalidIPv4Address(String)
    case invalidOwnershipMarker(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIPv4Address(let address):
            return "\(address) is not a valid IPv4 address."
        case .invalidOwnershipMarker(let reason):
            return "The metadata-address ownership marker is invalid: \(reason)"
        }
    }
}

public struct DarwinInterfaceAliasSystem: InterfaceAliasSystem {
    private static let markerContents = Data("quorra-imds-alias-v1\n".utf8)

    private let commandRunner: any SystemCommandRunning
    private let expectedOwnerUserID: uid_t

    public init() {
        commandRunner = FoundationSystemCommandRunner()
        expectedOwnerUserID = 0
    }

    init(
        commandRunner: any SystemCommandRunning,
        expectedOwnerUserID: uid_t
    ) {
        self.commandRunner = commandRunner
        self.expectedOwnerUserID = expectedOwnerUserID
    }

    public func interfaceName(containingIPv4Address address: String) throws -> String? {
        var expectedAddress = in_addr()
        guard inet_pton(AF_INET, address, &expectedAddress) == 1 else {
            throw DarwinInterfaceAliasSystemError.invalidIPv4Address(address)
        }

        var firstInterface: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstInterface) == 0 else {
            throw currentPOSIXError()
        }
        defer { freeifaddrs(firstInterface) }

        var currentInterface = firstInterface
        while let interface = currentInterface {
            defer { currentInterface = interface.pointee.ifa_next }
            guard let rawAddress = interface.pointee.ifa_addr,
                  rawAddress.pointee.sa_family == sa_family_t(AF_INET) else {
                continue
            }

            let socketAddress = UnsafeRawPointer(rawAddress)
                .assumingMemoryBound(to: sockaddr_in.self)
                .pointee
            guard socketAddress.sin_addr.s_addr == expectedAddress.s_addr else {
                continue
            }

            return String(cString: interface.pointee.ifa_name)
        }

        return nil
    }

    public func addIPv4Alias(
        address: String,
        prefixLength: Int,
        to interfaceName: String
    ) throws {
        try commandRunner.run(
            executableURL: URL(filePath: "/sbin/ifconfig"),
            arguments: [interfaceName, "inet", "\(address)/\(prefixLength)", "alias"]
        )
    }

    public func removeIPv4Alias(address: String, from interfaceName: String) throws {
        try commandRunner.run(
            executableURL: URL(filePath: "/sbin/ifconfig"),
            arguments: [interfaceName, "inet", address, "-alias"]
        )
    }

    public func hasOwnershipMarker(at url: URL) throws -> Bool {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return false
            }
            throw currentPOSIXError()
        }
        defer { Darwin.close(descriptor) }

        try validateMarkerMetadata(for: descriptor)
        let contents = try readAll(from: descriptor)
        guard contents == Self.markerContents else {
            throw DarwinInterfaceAliasSystemError.invalidOwnershipMarker(
                "its contents do not match the supported marker version"
            )
        }
        return true
    }

    public func createOwnershipMarker(at url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw currentPOSIXError()
        }

        var shouldRemoveMarker = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveMarker {
                Darwin.unlink(url.path)
            }
        }

        try validateMarkerMetadata(for: descriptor)
        try writeAll(Self.markerContents, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw currentPOSIXError()
        }
        shouldRemoveMarker = false
    }

    public func removeOwnershipMarker(at url: URL) throws {
        guard Darwin.unlink(url.path) == 0 else {
            if errno == ENOENT {
                return
            }
            throw currentPOSIXError()
        }
    }

    private func validateMarkerMetadata(for descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw currentPOSIXError()
        }

        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw DarwinInterfaceAliasSystemError.invalidOwnershipMarker(
                "it is not a regular file"
            )
        }
        guard metadata.st_uid == expectedOwnerUserID else {
            throw DarwinInterfaceAliasSystemError.invalidOwnershipMarker(
                "it is not owned by the expected user"
            )
        }
        guard metadata.st_mode & mode_t(0o777) == mode_t(0o600) else {
            throw DarwinInterfaceAliasSystemError.invalidOwnershipMarker(
                "its permissions are not 0600"
            )
        }
    }

    private func readAll(from descriptor: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 {
                return result
            }
            guard count > 0 else {
                if errno == EINTR {
                    continue
                }
                throw currentPOSIXError()
            }
            result.append(buffer, count: count)
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
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
                    if errno == EINTR {
                        continue
                    }
                    if count == 0 {
                        throw POSIXError(.EIO)
                    }
                    throw currentPOSIXError()
                }
                offset += count
            }
        }
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
