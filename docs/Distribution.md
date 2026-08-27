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

The Developer ID provisioning profile is required because Quorra claims the
restricted `keychain-access-groups` entitlement. The workflow imports both the
certificate and profile into the ephemeral GitHub-hosted runner, then removes
them when the job finishes.

In repository settings, allow GitHub Actions to create pull requests and give
workflows read/write repository permissions. Release Please uses the scoped
`GITHUB_TOKEN`; a separate personal access token is not needed because the DMG
is uploaded in the same workflow run that creates the GitHub release.

## Release verification

The workflow validates the exported application signature, validates the
notarization ticket after stapling, and assesses the DMG with Gatekeeper before
uploading it. Test a downloaded release on a separate user account before
announcing it, including launch from the mounted DMG and after moving the app
to `/Applications`.
