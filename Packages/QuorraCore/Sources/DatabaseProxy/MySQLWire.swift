import Foundation

nonisolated enum MySQLWire {
    static let protocol41: UInt32 = 0x200
    static let ssl: UInt32 = 0x800
    static let connectWithDB: UInt32 = 0x8
    static let secureConnection: UInt32 = 0x8000
    static let pluginAuth: UInt32 = 0x80000
    static let connectAttributes: UInt32 = 0x100000
    static let lengthEncodedAuth: UInt32 = 0x200000
    // Exclude compression, LOCAL INFILE, query attributes, session tracking,
    // optional result metadata and EOF deprecation on both sides of the relay.
    static let capabilities: UInt32 = 0x1 | 0x2 | 0x4 | connectWithDB | protocol41 | 0x2000
        | secureConnection | 0x10000 | 0x20000 | 0x40000 | pluginAuth | connectAttributes | lengthEncodedAuth
    static let maximumHandshake = 65_536

    static func integer(_ value: UInt64, bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    static func packet(_ payload: Data, sequence: UInt8) -> Data {
        precondition(payload.count <= 0xffffff)
        return integer(UInt64(payload.count), bytes: 3) + Data([sequence]) + payload
    }

    static func read(_ socket: PostgreSQLSocket, sequence: UInt8) async throws -> Data {
        var cursor = Cursor(try await socket.exact(4))
        let count = Int(try cursor.integer(3))
        guard try cursor.byte() == sequence, count <= maximumHandshake else { throw ProxyError.malformedMySQLMessage }
        return try await socket.exact(count)
    }

    static func lengthEncoded(_ bytes: Data) -> Data {
        let count = UInt64(bytes.count)
        let prefix: Data
        if count < 251 { prefix = Data([UInt8(count)]) }
        else if count <= 0xffff { prefix = Data([252]) + integer(count, bytes: 2) }
        else if count <= 0xffffff { prefix = Data([253]) + integer(count, bytes: 3) }
        else { prefix = Data([254]) + integer(count, bytes: 8) }
        return prefix + bytes
    }

    static func header(capabilities: UInt32, characterSet: UInt8) -> Data {
        integer(UInt64(capabilities), bytes: 4) + integer(64 * 1024 * 1024, bytes: 4)
            + Data([characterSet]) + Data(repeating: 0, count: 23)
    }

    static func greeting(nonce: Data, connectionID: UInt32, capabilities: UInt32 = capabilities) -> Data {
        precondition(nonce.count == 20)
        var result = Data([10]) + Data("8.4.0-Quorra\0".utf8)
        result += integer(UInt64(connectionID), bytes: 4) + nonce.prefix(8) + Data([0])
        result += integer(UInt64(capabilities & 0xffff), bytes: 2) + Data([45])
        result += integer(2, bytes: 2) + integer(UInt64(capabilities >> 16), bytes: 2)
        result += Data([21]) + Data(repeating: 0, count: 10)
        result += nonce.suffix(12) + Data([0]) + Data("caching_sha2_password\0".utf8)
        return result
    }

    static func error(_ error: any Error) -> Data {
        let message = ProxyCoordinator.message(error)
        let denied = (error as? ProxyError) == .localAuthentication
        return Data([255]) + integer(denied ? 1045 : 2000, bytes: 2)
            + Data((denied ? "#28000" : "#HY000").utf8) + Data(message.utf8)
    }

    struct Greeting: Sendable {
        let capabilities: UInt32
        let nonce: Data
        let plugin: String

        init(_ payload: Data) throws {
            var cursor = Cursor(payload)
            guard try cursor.byte() == 10 else { throw ProxyError.unsupportedMySQLProtocol }
            _ = try cursor.string()
            _ = try cursor.integer(4)
            let first = try cursor.take(8)
            guard try cursor.byte() == 0 else { throw ProxyError.malformedMySQLMessage }
            let lower = try cursor.integer(2)
            _ = try cursor.byte()
            _ = try cursor.integer(2)
            capabilities = UInt32(lower | (try cursor.integer(2) << 16))
            let length = Int(try cursor.byte())
            _ = try cursor.take(10)
            guard capabilities & MySQLWire.protocol41 != 0, capabilities & MySQLWire.pluginAuth != 0,
                  capabilities & MySQLWire.secureConnection != 0, (20...21).contains(length) else {
                throw ProxyError.unsupportedMySQLProtocol
            }
            let second = try cursor.take(max(13, length - 8))
            nonce = first + second.prefix(12)
            plugin = try cursor.string()
            guard cursor.remaining == 0 else { throw ProxyError.malformedMySQLMessage }
        }
    }

    struct ClientHandshake: Sendable {
        let capabilities: UInt32
        let characterSet: UInt8
        let username: String
        let database: String?
        let plugin: String
        let response: Data
        let attributes: Data

        init(_ payload: Data) throws {
            var cursor = Cursor(payload)
            let advertised = UInt32(try cursor.integer(4))
            // MySQL clients advertise supported features, including features the
            // server did not offer. Only the intersection is negotiated.
            // https://dev.mysql.com/doc/dev/mysql-server/latest/group__group__cs__capabilities__flags.html
            capabilities = advertised & MySQLWire.capabilities
            guard capabilities & MySQLWire.protocol41 != 0, capabilities & MySQLWire.secureConnection != 0,
                  advertised & MySQLWire.ssl == 0 else { throw ProxyError.unsupportedMySQLProtocol }
            _ = try cursor.integer(4)
            characterSet = try cursor.byte()
            guard characterSet != 0 else { throw ProxyError.unsupportedMySQLProtocol }
            _ = try cursor.take(23)
            username = try cursor.string()
            if capabilities & MySQLWire.lengthEncodedAuth != 0 { response = try cursor.lengthEncoded() }
            else { response = try cursor.take(Int(cursor.byte())) }
            database = capabilities & MySQLWire.connectWithDB != 0 ? try cursor.string() : nil
            plugin = capabilities & MySQLWire.pluginAuth != 0 ? try cursor.string() : "mysql_native_password"
            attributes = capabilities & MySQLWire.connectAttributes != 0 ? try cursor.lengthEncoded() : Data()
            guard cursor.remaining == 0 else { throw ProxyError.malformedMySQLMessage }
        }
    }

    struct Cursor {
        private let data: Data
        private var offset = 0
        var remaining: Int { data.count - offset }
        init(_ data: Data) { self.data = Data(data) }
        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= remaining else { throw ProxyError.malformedMySQLMessage }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }
        mutating func byte() throws -> UInt8 { try take(1)[0] }
        mutating func integer(_ count: Int) throws -> UInt64 {
            guard (1...8).contains(count) else { throw ProxyError.malformedMySQLMessage }
            return try take(count).enumerated().reduce(0) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
        }
        mutating func string() throws -> String {
            guard let end = data[offset...].firstIndex(of: 0) else { throw ProxyError.malformedMySQLMessage }
            let bytes = try take(end - offset)
            _ = try byte()
            guard let value = String(data: bytes, encoding: .utf8) else { throw ProxyError.malformedMySQLMessage }
            return value
        }
        mutating func lengthEncoded() throws -> Data {
            let first = try byte()
            let length: UInt64
            switch first {
            case 0...250: length = UInt64(first)
            case 252: length = try integer(2)
            case 253: length = try integer(3)
            case 254: length = try integer(8)
            default: throw ProxyError.malformedMySQLMessage
            }
            guard length <= UInt64(remaining) else { throw ProxyError.malformedMySQLMessage }
            return try take(Int(length))
        }
    }
}
