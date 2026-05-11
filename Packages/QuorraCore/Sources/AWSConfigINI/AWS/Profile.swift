// Profile.swift — Codable struct for an AWS config profile.
//
// Plan §5 (D10 lean surface), §13.2 task 3.
// Field names use camelCase; the default AWSConfigINIDecoder/Encoder strategy
// (.convertFromSnakeCase / .convertToSnakeCase) maps them to/from the AWS INI
// key names automatically:
//
//   ssoSession          ↔ sso_session
//   credentialProcess   ↔ credential_process
//   sourceProfile       ↔ source_profile
//   roleArn             ↔ role_arn
//   roleSessionName     ↔ role_session_name
//   mfaSerial           ↔ mfa_serial
//
// No explicit CodingKeys are needed — the convertToSnakeCase strategy handles
// all of these correctly (verified in AWSOverlayTests). Plan §13.2 task 3 audit.

/// A lean model of an AWS shared-config profile.
///
/// Covers the fields Quorra needs for SSO, credential-process, and role-assumption
/// flows. Other settings are accessible via the raw `Section`/`Key` accessors.
///
/// Decode with `AWSConfigINIDecoder.decodeProfile(_:named:from:)` or the
/// lower-level `decode(_:from:section:)` passing the verbatim section name.
/// Plan §5 (D10); §13.2 task 3.
public struct Profile: Codable, Sendable, Hashable {
    public var region: String?
    public var output: String?
    /// Corresponds to the `sso_session` INI key.
    public var ssoSession: String?
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
        credentialProcess: String? = nil,
        sourceProfile: String? = nil,
        roleArn: String? = nil,
        roleSessionName: String? = nil,
        mfaSerial: String? = nil
    ) {
        self.region = region
        self.output = output
        self.ssoSession = ssoSession
        self.credentialProcess = credentialProcess
        self.sourceProfile = sourceProfile
        self.roleArn = roleArn
        self.roleSessionName = roleSessionName
        self.mfaSerial = mfaSerial
    }
}
