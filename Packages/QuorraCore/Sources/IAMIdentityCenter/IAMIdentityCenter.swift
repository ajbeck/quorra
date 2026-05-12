// IAMIdentityCenter — OAuth 2.0 device authorization grant for AWS IAM Identity Center.
//
// Implements the full device-code sign-in flow (RFC 8628) against the AWS SSO OIDC service,
// persists tokens in the macOS Keychain, and exposes a single high-level `signIn` operation.
// No on-disk cache — all secrets live in the shared Keychain access group.
//
// The primary public API entry point is `IdentityCenterService.signIn(...)`.

import Foundation
