import Foundation

/// An IAM Identity Center permission set (role) entry from `ListAccountRoles`.
///
/// Each element corresponds to one role the authenticated user can assume in a given account,
/// as returned by `GET /assignment/roles?account_id=<id>` on the IAM Identity Center Portal API.
public struct PortalRole: Sendable, Hashable, Codable {
    /// 12-digit AWS account identifier this role belongs to.
    public let accountId: String

    /// IAM Identity Center permission set name (role name).
    public let roleName: String

    public init(accountId: String, roleName: String) {
        self.accountId = accountId
        self.roleName = roleName
    }
}
