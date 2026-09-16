import Foundation

extension IdentityCenterService {
    // MARK: - Portal listing

    /// Lists the accounts the signed-in user is assigned to through `sessionName`.
    ///
    /// The portal host is region-scoped to the session's Identity Center region, which the stored
    /// token carries: AWS documents `sso_region` as "the AWS Region that contains your IAM Identity
    /// Center portal host" (https://docs.aws.amazon.com/sdkref/latest/guide/feature-sso-credentials.html).
    /// `liveToken` refreshes the bearer first, so a signed-out session throws `.notSignedIn` and an
    /// unrefreshable one throws `.tokenExpired`.
    @concurrent
    public func accounts(forSession sessionName: String) async throws -> [PortalAccount] {
        try await self.performListAccounts(sessionName: sessionName)
    }

    /// Lists the roles the signed-in user can assume in `accountId` through `sessionName`.
    @concurrent
    public func roles(forSession sessionName: String, accountId: String) async throws -> [PortalRole] {
        try await self.performListRoles(sessionName: sessionName, accountId: accountId)
    }

    func performListAccounts(sessionName: String) async throws -> [PortalAccount] {
        let token = try await liveToken(forSession: sessionName)
        return try await portalClient.listAccounts(accessToken: token.accessToken, region: token.region)
    }

    func performListRoles(sessionName: String, accountId: String) async throws -> [PortalRole] {
        let token = try await liveToken(forSession: sessionName)
        return try await portalClient.listAccountRoles(
            accessToken: token.accessToken,
            accountId: accountId,
            region: token.region
        )
    }
}
