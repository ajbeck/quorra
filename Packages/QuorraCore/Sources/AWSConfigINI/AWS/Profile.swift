/// A lean model of an AWS shared-config profile.
///
/// Covers the fields Quorra needs for SSO, credential-process, and role-assumption
/// flows. Other settings are accessible via the raw `Section`/`Key` accessors.
///
/// Decode with `AWSConfigINIDecoder.decodeProfile(_:named:from:)` or the
/// lower-level `decode(_:from:section:)` passing the verbatim section name.
///
/// Field names use camelCase and round-trip through the default
/// `convertToSnakeCase` / `convertFromSnakeCase` strategies — no explicit
/// `CodingKeys` are needed.
public struct Profile: Codable, Sendable, Hashable {
    public var region: String?
    public var output: String?
    /// Corresponds to the `sso_session` INI key.
    public var ssoSession: String?
    /// Corresponds to the legacy inline `sso_start_url` INI key.
    public var ssoStartUrl: String?
    /// Corresponds to the legacy inline `sso_region` INI key.
    public var ssoRegion: String?
    /// Corresponds to the `sso_account_id` INI key.
    public var ssoAccountId: String?
    /// Corresponds to the `sso_role_name` INI key.
    public var ssoRoleName: String?
    /// Corresponds to the `credential_process` INI key.
    public var credentialProcess: String?
    /// Corresponds to the `source_profile` INI key.
    public var sourceProfile: String?
    /// Corresponds to the `role_arn` INI key.
    public var roleArn: String?
    /// Corresponds to the `role_session_name` INI key.
    public var roleSessionName: String?
    /// Corresponds to the `mfa_serial` INI key.
    public var mfaSerial: String?

    public init(
        region: String? = nil,
        output: String? = nil,
        ssoSession: String? = nil,
        ssoStartUrl: String? = nil,
        ssoRegion: String? = nil,
        ssoAccountId: String? = nil,
        ssoRoleName: String? = nil,
        credentialProcess: String? = nil,
        sourceProfile: String? = nil,
        roleArn: String? = nil,
        roleSessionName: String? = nil,
        mfaSerial: String? = nil
    ) {
        self.region = region
        self.output = output
        self.ssoSession = ssoSession
        self.ssoStartUrl = ssoStartUrl
        self.ssoRegion = ssoRegion
        self.ssoAccountId = ssoAccountId
        self.ssoRoleName = ssoRoleName
        self.credentialProcess = credentialProcess
        self.sourceProfile = sourceProfile
        self.roleArn = roleArn
        self.roleSessionName = roleSessionName
        self.mfaSerial = mfaSerial
    }
}
