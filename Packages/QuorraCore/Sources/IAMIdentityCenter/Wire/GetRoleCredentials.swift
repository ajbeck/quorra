import Foundation

extension Wire {
    /// Response envelope for `GET /federation/credentials`.
    ///
    /// AWS returns credentials nested under `roleCredentials`.
    /// `expiration` is **Unix milliseconds** (not seconds) per the Portal API reference.
    internal struct GetRoleCredentialsResponse: Codable, Sendable {
        let roleCredentials: RoleCredentialsPayload

        internal struct RoleCredentialsPayload: Codable, Sendable {
            let accessKeyId: String
            let secretAccessKey: String
            let sessionToken: String
            /// Unix epoch milliseconds. Divide by 1000 to get `TimeInterval` for `Date(timeIntervalSince1970:)`.
            let expiration: Int64
        }
    }
}
