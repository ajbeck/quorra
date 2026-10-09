import AWSRDS
import Foundation
import IAMIdentityCenter
import SmithyIdentity

actor RDSIAMTokenGenerator {
    func generate(credentials: RoleCredentials, host: String, port: Int, region: String, username: String) async throws -> String {
        guard credentials.expiresAt > Date.now.addingTimeInterval(60) else { throw IAMIdentityCenterError.tokenExpired }
        guard (1...65535).contains(port) else { throw ConfigurationError.invalidPort("Upstream port") }
        let validation = ConnectionDraft(name: "RDS", engine: .postgresql, host: host, upstreamPort: port, localPort: 15432,
                                         credential: .init(kind: .awsIAM, id: UUID()), iamDatabaseUsername: username, awsRegion: region)
        let validated = try validation.validated()
        let identity = AWSCredentialIdentity(accessKey: credentials.accessKeyId, secret: credentials.secretAccessKey,
                                             accountID: credentials.accountId, expiration: credentials.expiresAt,
                                             sessionToken: credentials.sessionToken)
        // AWS's public helper uses SigV4 with service rds-db and preserves the
        // real upstream host/port. The returned token never enters persistence.
        return try await AWSRDS.AuthTokenGenerator(awsCredentialIdentity: identity).generateAuthToken(
            endpoint: validated.host, port: UInt16(port), region: validated.awsRegion, username: username,
            expiration: min(900, credentials.expiresAt.timeIntervalSinceNow)
        )
    }
}
