# Distribution

Quorra releases are created by Release Please after a release pull request is
merged into `main`. The release workflow builds, signs, notarizes, staples, and
uploads a DMG to the resulting GitHub release.

## Repository files

- `version.txt` is the current release baseline managed by Release Please.
- `CHANGELOG.md` is generated and updated by Release Please.
- `.github/scripts/package-dmg.sh` creates the signed, read-only DMG. It uses
  Apple's `ditto`, `hdiutil`, and `codesign` tools; no third-party packaging
  dependency is involved. The DMG includes `THIRD_PARTY_NOTICES.md` beside the
  app bundle.
- `THIRD_PARTY_NOTICES.md` indexes the packages pinned in `Package.resolved`
  and reproduces their upstream notice text. Update it when changing package
  versions or dependencies.

## GitHub configuration

The workflow needs these repository secrets before a release can be packaged:

| Secret | Purpose |
| --- | --- |
| `APPLE_DEVELOPER_ID_CERTIFICATE_BASE64` | Base64-encoded Developer ID Application certificate (`.p12`). |
| `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password for the certificate export. |
| `APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64` | Base64-encoded Developer ID provisioning profile for `dev.ajbeck.quorra`. |
| `APPLE_DEVELOPER_ID_LOGIN_ITEM_PROVISIONING_PROFILE_BASE64` | Base64-encoded Developer ID provisioning profile for `dev.ajbeck.quorra.login-item`. |
| `APPLE_DEVELOPER_ID_SYSTEM_EXTENSION_PROVISIONING_PROFILE_BASE64` | Base64-encoded Developer ID provisioning profile for `dev.ajbeck.quorra.imds-proxy`. |
| `APPLE_NOTARY_KEY_BASE64` | Base64-encoded App Store Connect API private key (`.p8`). |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key identifier. |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect API issuer identifier. |
| `RELEASE_PLEASE_APP_PRIVATE_KEY` | Private PEM key for the `ajbeck Release Please` GitHub App. |

The workflow also needs the repository variable `RELEASE_PLEASE_APP_ID`, which
identifies the `ajbeck Release Please` GitHub App. Install that App on the
repository with read/write access to
Contents, Issues, and Pull requests. The workflow creates an installation token
scoped to its current repository and uses it for Release Please and uploading
the DMG. This lets the release pull request trigger the normal pull-request
validation workflow.

The three Developer ID provisioning profiles are required because Quorra and
its nested components claim restricted entitlements. The host profile covers
the App Group, Network Extension, and system-extension installation
entitlements for `dev.ajbeck.quorra`. The login-item profile covers the App
Group used to read the shared menu-bar-only preference. The extension profile
covers the App Group and `app-proxy-provider-systemextension` entitlements for
`dev.ajbeck.quorra.imds-proxy`. The workflow verifies that all profiles use the
same Team ID, imports them with the certificate into the ephemeral GitHub-hosted
runner, and removes them when the job finishes.

The built-in `GITHUB_TOKEN` remains read-only. The GitHub App owns the release
automation write permissions, so no personal access token is needed.

## Release verification

The workflow validates that Quorra's four executables—the application, login
item, CLI, and nested system extension—contain only the Apple silicon `arm64`
architecture. It also validates their signatures and entitlements, validates
the notarization ticket after stapling, and assesses the DMG with Gatekeeper
before uploading it. Test a downloaded release on a separate user account
before announcing it, including normal Finder launch, quiet launch-at-login
behavior, launch from the mounted DMG, and system-extension activation after
moving the app to `/Applications`.

Before merging a Release Please pull request, run the **Release** workflow from
its branch with `candidate_version` set to the pending three-component version,
for example `0.6.0`. Candidate mode signs, exports, notarizes, staples, and
verifies the selected commit without creating or modifying a GitHub release. It
uploads the resulting DMG as a seven-day workflow artifact for clean-machine
testing. Leave `release_tag` empty in candidate mode.

Verify a candidate as both a fresh install and an in-place update from the
latest release. Exercise system-extension approval granted, deferred, and
denied; restart and sleep/wake; common VPN use; default AWS CLI and SDK
credential resolution without endpoint or region environment variables; and
app deletion. Do not merge the Release Please pull request until the candidate
passes this matrix.
