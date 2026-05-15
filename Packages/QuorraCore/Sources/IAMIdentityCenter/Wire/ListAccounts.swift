import Foundation

extension Wire {
    /// Response envelope for `GET /assignment/accounts`.
    ///
    /// `accountList` holds the page of accounts; `nextToken` is present when further pages remain.
    internal struct ListAccountsResponse: Codable, Sendable {
        let accountList: [AccountItem]
        let nextToken: String?

        internal struct AccountItem: Codable, Sendable {
            let accountId: String
            let accountName: String
            let emailAddress: String
        }
    }
}
