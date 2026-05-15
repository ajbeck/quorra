import Foundation

extension Wire {
    /// Response envelope for `GET /assignment/roles?account_id=<id>`.
    ///
    /// `roleList` holds the page of roles; `nextToken` is present when further pages remain.
    internal struct ListAccountRolesResponse: Codable, Sendable {
        let roleList: [RoleItem]
        let nextToken: String?

        internal struct RoleItem: Codable, Sendable {
            let accountId: String
            let roleName: String
        }
    }
}
