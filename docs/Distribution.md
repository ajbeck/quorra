# Distribution

Quorra releases are created by Release Please after a release pull request is
merged into `main`. The release workflow builds, signs, notarizes, staples, and
uploads a DMG to the resulting GitHub release.

## Repository files

- `version.txt` is the current release baseline managed by Release Please.
- `CHANGELOG.md` is generated and updated by Release Please.
- `.github/scripts/package-dmg.sh` creates the signed, read-only DMG. It uses
  Apple's `ditto`, `hdiutil`, and `codesign` tools; no third-party packaging
  dependency is involved.

## GitHub configuration

The workflow needs these repository secrets before a release can be packaged:

| Secret | Purpose |
| --- | --- |
| `APPLE_DEVELOPER_ID_CERTIFICATE_BASE64` | Base64-encoded Developer ID Application certificate (`.p12`). |
| `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password for the certificate export. |
| `APPLE_DEVELOPER_ID_PROVISIONING_PROFILE_BASE64` | Base64-encoded Developer ID provisioning profile for `dev.ajbeck.quorra`. |
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

The Developer ID provisioning profile is required because Quorra claims the
restricted `keychain-access-groups` entitlement. The workflow imports both the
certificate and profile into the ephemeral GitHub-hosted runner, then removes
them when the job finishes.

The built-in `GITHUB_TOKEN` remains read-only. The GitHub App owns the release
automation write permissions, so no personal access token is needed.

## Release verification

The workflow validates the exported application signature, validates the
notarization ticket after stapling, and assesses the DMG with Gatekeeper before
uploading it. Test a downloaded release on a separate user account before
announcing it, including launch from the mounted DMG and after moving the app
to `/Applications`.
