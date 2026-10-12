import Foundation

public enum ClientVPNWireError: Error, Equatable {
    case malformed
    case unsupportedVersion
    case tooLarge
}

/// The binary format of messages between the app and the packet tunnel (`sendProviderMessage`).
///
/// A message is `QVPN`, a version byte and a kind byte, then the kind's fields. IDs are 16 raw bytes;
/// variable fields are a big-endian `UInt32` length and the bytes. Binary rather than JSON so a SAML
/// assertion near AWS's 120 KiB limit isn't Base64-expanded past the message limit.
public enum ClientVPNWire {
    /// The `startTunnel` option carrying the app's run ID, as a UUID string.
    public static let startOption = "QuorraVPNRun"

    static let magic = Data("QVPN".utf8)
    static let version: UInt8 = 1

    enum Kind: UInt8 {
        case connect = 1, authenticate, status, stop, snapshot, rejected
    }

    public static func encode(_ request: ClientVPNLiveRequest) throws -> Data {
        var writer: Writer
        switch request {
        case .connect(let run, let profile, let token):
            guard profile.utf8.count <= ClientVPNLimits.profileBytes else { throw ClientVPNLiveFailure.invalidProfile }
            guard token?.isWithinLimits ?? true else { throw ClientVPNLiveFailure.invalidCredentials }
            writer = Writer(.connect)
            writer.uuid(run)
            writer.field(Data(profile.utf8))
            writer.token(token)
        case .authenticate(let run, let challenge, let assertion):
            guard !assertion.isEmpty, assertion.count <= ClientVPNLimits.credentialBytes else { throw ClientVPNLiveFailure.invalidCredentials }
            writer = Writer(.authenticate)
            writer.uuid(run)
            writer.uuid(challenge)
            writer.field(assertion)
        case .status(let run):
            writer = Writer(.status)
            writer.uuid(run)
        case .stop(let run):
            writer = Writer(.stop)
            writer.uuid(run)
        }
        return try writer.finish()
    }

    public static func decodeRequest(_ data: Data) throws -> ClientVPNLiveRequest {
        var reader = try Reader(data)
        let request: ClientVPNLiveRequest
        switch reader.kind {
        case .connect:
            let run = try reader.uuid()
            let profile = try reader.string(max: ClientVPNLimits.profileBytes)
            request = .connect(run: run, profile: profile, token: try reader.token())
        case .authenticate:
            let run = try reader.uuid()
            let challenge = try reader.uuid()
            let assertion = try reader.field(max: ClientVPNLimits.credentialBytes)
            guard !assertion.isEmpty else { throw ClientVPNWireError.malformed }
            request = .authenticate(run: run, challenge: challenge, assertion: assertion)
        case .status:
            request = .status(run: try reader.uuid())
        case .stop:
            request = .stop(run: try reader.uuid())
        case .snapshot, .rejected:
            throw ClientVPNWireError.malformed
        }
        try reader.finish()
        return request
    }

    public static func encode(_ response: ClientVPNLiveResponse) throws -> Data {
        var writer: Writer
        switch response {
        case .snapshot(let snapshot):
            writer = Writer(.snapshot)
            writer.uuid(snapshot.run)
            writer.byte(snapshot.phase.rawValue)
            writer.byte(snapshot.failure.map { UInt8($0.rawValue) } ?? 0)
            writer.uint64(snapshot.packets.sent)
            writer.uint64(snapshot.packets.received)
            if let challenge = snapshot.challenge {
                writer.byte(1)
                writer.uuid(challenge.id)
                writer.field(Data(challenge.url.absoluteString.utf8))
            } else {
                writer.byte(0)
            }
            writer.token(snapshot.token)
            if let tunnel = snapshot.tunnel {
                writer.byte(1)
                writer.entries(tunnel.addresses)
                writer.entries(tunnel.routes)
                writer.uint32(UInt32(clamping: tunnel.omittedRoutes))
                writer.entries(tunnel.dnsServers)
            } else {
                writer.byte(0)
            }
        case .rejected(let failure):
            writer = Writer(.rejected)
            writer.byte(UInt8(failure.rawValue))
        }
        return try writer.finish()
    }

    public static func decodeResponse(_ data: Data) throws -> ClientVPNLiveResponse {
        var reader = try Reader(data)
        let response: ClientVPNLiveResponse
        switch reader.kind {
        case .snapshot:
            let run = try reader.uuid()
            guard let phase = ClientVPNLivePhase(rawValue: try reader.byte()) else { throw ClientVPNWireError.malformed }
            let failureCode = try reader.byte()
            let failure = failureCode == 0 ? nil : try Self.failure(failureCode)
            let packets = ClientVPNPacketCounts(sent: try reader.uint64(), received: try reader.uint64())
            let challenge: ClientVPNBrowserChallenge?
            switch try reader.byte() {
            case 0:
                challenge = nil
            case 1:
                let id = try reader.uuid()
                guard let url = URL(string: try reader.string(max: ClientVPNLimits.messageBytes)) else { throw ClientVPNWireError.malformed }
                challenge = .init(id: id, url: url)
            default:
                throw ClientVPNWireError.malformed
            }
            let token = try reader.token()
            let tunnel: ClientVPNTunnelSettings?
            switch try reader.byte() {
            case 0:
                tunnel = nil
            case 1:
                let addresses = try reader.entries()
                let routes = try reader.entries()
                let omittedRoutes = Int(try reader.uint32())
                tunnel = .init(addresses: addresses, routes: routes, omittedRoutes: omittedRoutes, dnsServers: try reader.entries())
            default:
                throw ClientVPNWireError.malformed
            }
            response = .snapshot(.init(run: run, phase: phase, challenge: challenge, token: token, failure: failure, packets: packets, tunnel: tunnel))
        case .rejected:
            response = .rejected(try failure(try reader.byte()))
        case .connect, .authenticate, .status, .stop:
            throw ClientVPNWireError.malformed
        }
        try reader.finish()
        return response
    }

    private static func failure(_ code: UInt8) throws -> ClientVPNLiveFailure {
        guard let failure = ClientVPNLiveFailure(rawValue: Int(code)) else { throw ClientVPNWireError.malformed }
        return failure
    }
}

extension ClientVPNWire {
    private struct Writer {
        private var data: Data

        init(_ kind: Kind) {
            data = magic
            data.append(version)
            data.append(kind.rawValue)
        }

        mutating func byte(_ value: UInt8) { data.append(value) }
        mutating func uint32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        mutating func uint64(_ value: UInt64) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        mutating func uuid(_ id: UUID) { withUnsafeBytes(of: id.uuid) { data.append(contentsOf: $0) } }

        mutating func field(_ bytes: Data) {
            // An oversized field clamps here and then fails the size check in `finish`.
            uint32(UInt32(clamping: bytes.count))
            data.append(bytes)
        }

        /// A count, then each entry as a field.
        mutating func entries(_ entries: [String]) {
            uint32(UInt32(clamping: entries.count))
            for entry in entries { field(Data(entry.utf8)) }
        }

        /// A token as two fields, both empty when there's none.
        mutating func token(_ token: ClientVPNLiveToken?) {
            field(token?.username ?? Data())
            field(token?.token ?? Data())
        }

        func finish() throws -> Data {
            guard data.count <= ClientVPNLimits.messageBytes else { throw ClientVPNWireError.tooLarge }
            return data
        }
    }

    private struct Reader {
        let kind: Kind
        private let bytes: [UInt8]
        private var offset: Int

        init(_ data: Data) throws {
            bytes = [UInt8](data)
            let header = magic.count + 2
            guard bytes.count >= header, bytes.count <= ClientVPNLimits.messageBytes, bytes.starts(with: magic) else { throw ClientVPNWireError.malformed }
            guard bytes[magic.count] == version else { throw ClientVPNWireError.unsupportedVersion }
            guard let kind = Kind(rawValue: bytes[magic.count + 1]) else { throw ClientVPNWireError.malformed }
            self.kind = kind
            offset = header
        }

        private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count <= bytes.count - offset else { throw ClientVPNWireError.malformed }
            defer { offset += count }
            return bytes[offset..<offset + count]
        }

        mutating func byte() throws -> UInt8 { try take(1).first ?? 0 }
        mutating func uint32() throws -> UInt32 { try take(4).reduce(0) { $0 << 8 | UInt32($1) } }
        mutating func uint64() throws -> UInt64 { try take(8).reduce(0) { $0 << 8 | UInt64($1) } }
        mutating func uuid() throws -> UUID { Array(try take(16)).withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) } }

        mutating func field(max: Int) throws -> Data {
            let length = Int(try uint32())
            guard length <= max else { throw ClientVPNWireError.malformed }
            return Data(try take(length))
        }

        mutating func entries() throws -> [String] {
            let count = Int(try uint32())
            guard count <= ClientVPNLimits.tunnelEntries else { throw ClientVPNWireError.malformed }
            return try (0..<count).map { _ in
                let entry = try string(max: ClientVPNLimits.tunnelEntryBytes)
                guard !entry.isEmpty else { throw ClientVPNWireError.malformed }
                return entry
            }
        }

        mutating func string(max: Int) throws -> String {
            guard let value = String(data: try field(max: max), encoding: .utf8) else { throw ClientVPNWireError.malformed }
            return value
        }

        mutating func token() throws -> ClientVPNLiveToken? {
            let username = try field(max: ClientVPNLimits.tokenUsernameBytes)
            let token = try field(max: ClientVPNLimits.credentialBytes)
            if username.isEmpty && token.isEmpty { return nil }
            let value = ClientVPNLiveToken(username: username, token: token)
            guard value.isWithinLimits else { throw ClientVPNWireError.malformed }
            return value
        }

        func finish() throws {
            guard offset == bytes.count else { throw ClientVPNWireError.malformed }
        }
    }
}
