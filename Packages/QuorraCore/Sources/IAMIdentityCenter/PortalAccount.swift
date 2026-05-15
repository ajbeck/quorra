import Foundation

/// An AWS account entry from `ListAccounts`.
///
/// Each element corresponds to one account the authenticated user is assigned to,
/// as returned by `GET /assignment/accounts` on the IAM Identity Center Portal API.
public struct PortalAccount: Sendable, Hashable, Codable {
    /// 12-digit AWS account identifier.
    public let accountId: String

    /// Human-readable account name.
    public let accountName: String

    /// Primary email address associated with the account.
    public let emailAddress: String

    public init(accountId: String, accountName: String, emailAddress: String) {
        self.accountId = accountId
        self.accountName = accountName
        self.emailAddress = emailAddress
    }
}
