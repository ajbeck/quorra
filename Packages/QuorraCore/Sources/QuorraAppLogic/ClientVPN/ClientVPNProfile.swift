import ClientVPN
import Foundation

public enum ClientVPNProfileError: Error, Equatable, LocalizedError {
    case tooLarge, notText, missingRemote, multipleRemotes, invalidRemote, invalidEndpoint
    case missingName, missingFromKeychain
    /// The names of the databases using the VPN.
    case inUse([String])

    public var errorDescription: String? {
        switch self {
        case .missingName: "Name is required."
        case .missingFromKeychain: "Quorra couldn't find this VPN's profile in the Keychain. Replace it with the .ovpn file exported from AWS Client VPN."
        case .inUse(let names):
            "\(ListFormatter.localizedString(byJoining: names)) \(names.count == 1 ? "uses" : "use") this VPN. Choose another VPN for \(names.count == 1 ? "it" : "them"), then delete it."
        case .tooLarge: "This file is larger than 64 KB. Choose the .ovpn file exported from AWS Client VPN."
        case .notText: "This file isn't a text VPN profile. Choose the .ovpn file exported from AWS Client VPN."
        case .missingRemote: "This profile has no remote line naming the VPN server."
        case .multipleRemotes: "This profile names more than one VPN server. Quorra supports profiles with one remote line."
        case .invalidRemote: "This profile's remote line has an invalid port or protocol."
        case .invalidEndpoint: "The VPN server must be a DNS name, such as cvpn-endpoint-0123456789abcdef0.prod.clientvpn.eu-west-2.amazonaws.com."
        }
    }
}

/// An imported AWS Client VPN `.ovpn` profile: what Quorra shows about it, and its endpoint, which
/// Quorra can replace.
///
/// The endpoint is the host on the one `remote host [port] [proto]` line (OpenVPN reference manual,
/// `--remote`). AWS profiles carry `remote-random-hostname`, which puts a random label in front of
/// that host, so it must be a DNS name rather than an IP address.
public struct ClientVPNProfile: Equatable, Sendable {
    public enum Transport: String, Sendable {
        case udp = "UDP", tcp = "TCP"
    }

    public let text: String
    public let endpoint: String
    public let port: Int
    public let transport: Transport
    /// Whether the server asks for a browser sign-in (SAML, `auth-federate`) rather than only the client certificate.
    public let usesBrowserSignIn: Bool
    private let endpointRange: Range<String.Index>

    /// Reads a profile the user picked, off the main actor, refusing anything but a small regular file.
    public static func load(from url: URL) async throws -> ClientVPNProfile {
        try await Task.detached(priority: .userInitiated) {
            guard url.isFileURL else { throw ClientVPNProfileError.notText }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw ClientVPNProfileError.notText }
            guard (values.fileSize ?? 0) <= ClientVPNLimits.profileBytes else { throw ClientVPNProfileError.tooLarge }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            return try ClientVPNProfile(data: try file.read(upToCount: ClientVPNLimits.profileBytes + 1) ?? Data())
        }.value
    }

    /// Checks the size and encoding of a file before parsing it.
    public init(data: Data) throws {
        guard data.count <= ClientVPNLimits.profileBytes else { throw ClientVPNProfileError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw ClientVPNProfileError.notText }
        try self.init(text: text)
    }

    public init(text: String) throws {
        guard text.utf8.count <= ClientVPNLimits.profileBytes else { throw ClientVPNProfileError.tooLarge }
        // Splitting on Character keeps a CRLF line break as one separator, and the fields keep their
        // positions in `text`.
        let lines = text.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace) }
        let remotes = lines.filter { $0.first == "remote" }
        guard let remote = remotes.first else { throw ClientVPNProfileError.missingRemote }
        guard remotes.count == 1 else { throw ClientVPNProfileError.multipleRemotes }
        guard (2...4).contains(remote.count) else { throw ClientVPNProfileError.invalidRemote }
        guard Self.isDNSName(remote[1]) else { throw ClientVPNProfileError.invalidEndpoint }

        // OpenVPN's defaults when the remote line leaves them out: port 1194, and the `proto` directive or UDP.
        let port = remote.count > 2 ? Int(remote[2]) : 1194
        guard let port, (1...65_535).contains(port) else { throw ClientVPNProfileError.invalidRemote }
        let proto = remote.count > 3 ? remote[3] : lines.last { $0.first == "proto" && $0.count == 2 }?[1] ?? "udp"
        guard let transport = Self.transport(proto) else { throw ClientVPNProfileError.invalidRemote }

        self.text = text
        endpoint = String(remote[1])
        endpointRange = remote[1].startIndex..<remote[1].endIndex
        self.port = port
        self.transport = transport
        usesBrowserSignIn = lines.contains { $0.first == "auth-federate" }
    }

    /// The profile with `endpoint` in place of its own; only the host changes, so the profile's own
    /// endpoint gives back the imported text exactly.
    public func text(endpoint: String) throws -> String {
        let endpoint = try Self.endpoint(from: endpoint)
        var text = text
        text.replaceSubrange(endpointRange, with: endpoint)
        return text
    }

    /// A typed endpoint, trimmed and checked to be a DNS name.
    public static func endpoint(from input: String) throws -> String {
        let endpoint = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isDNSName(endpoint[...]) else { throw ClientVPNProfileError.invalidEndpoint }
        return endpoint
    }

    /// Letters, digits and hyphens in labels of 1 to 63 characters, at most 253 in all (RFC 1123), with
    /// a top-level label that isn't all digits so an IPv4 address doesn't pass (RFC 3696 section 2).
    private static func isDNSName(_ host: Substring) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let digits: ClosedRange<UInt8> = 0x30...0x39
        guard host.utf8.count <= 253, let last = labels.last, !last.utf8.allSatisfy(digits.contains) else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { digits.contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x2D }
        }
    }

    private static func transport(_ proto: Substring) -> Transport? {
        switch proto.lowercased() {
        case "udp", "udp4", "udp6": .udp
        case "tcp", "tcp4", "tcp6", "tcp-client", "tcp4-client", "tcp6-client": .tcp
        default: nil
        }
    }
}
