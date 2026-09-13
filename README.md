# Quorra

Quorra is a native macOS app for managing AWS IAM Identity Center sessions,
profiles, temporary credentials, and local IMDS endpoints.

It is for developers who move between AWS accounts and roles and want a
visible, local workflow instead of repeatedly running `aws sso login`, editing
`~/.aws/config` by hand, or passing credentials through a collection of shell
scripts. Quorra reads the standard AWS shared configuration, keeps IAM Identity
Center tokens and temporary role credentials in the macOS Keychain, and can
serve a profile through an IMDS endpoint for local AWS tooling.

## Screenshots

![Profiles and credentials](docs/images/profiles-and-credentials.png)

![Running IMDS endpoint](docs/images/imds-endpoint.png)

## Install

Quorra requires macOS 26 (Tahoe) or later.

1. Download `Quorra.dmg` from the [latest GitHub release](https://github.com/ajbeck/quorra/releases/latest).
2. Open the disk image and move `Quorra.app` to `/Applications`.
3. Open Quorra and grant access to your AWS folder, normally `~/.aws`.
4. Choose **Edit & Manage** to let Quorra update AWS configuration files, or
   **Read Only** to browse profiles and use credentials without changing them.

Quorra must be installed in `/Applications` before the default EC2 metadata
endpoint can be enabled. The first time you enable it, macOS asks you to approve
the system extension and then enable Quorra's Network Extension:

1. Allow the system extension when macOS presents the approval request.
2. Open **System Settings → General → Login Items & Extensions**.
3. Under **Extensions**, click the info button beside Quorra's Network
   Extension and turn it on.

Quorra continues starting the endpoint automatically after macOS completes the
approval. These approvals persist across ordinary endpoint restarts and app
launches.

The first public release is being prepared. Until then, build the app from
source using Xcode 26 or later:

```sh
git clone https://github.com/ajbeck/quorra.git
cd quorra
open Quorra.xcworkspace
```

Run the `QuorraApp` scheme with Command-R.

## What It Does

- Browse AWS IAM Identity Center sessions, profiles, and app-owned IMDS
  endpoints in a three-column macOS interface.
- Sign in with AWS IAM Identity Center through the native device authorization
  flow, refresh sessions, and inspect credential expiry.
- Copy temporary credentials as shell environment variables.
- Manage AWS profile and session configuration in the selected AWS folder.
- Start the default endpoint at AWS's standard metadata URL,
  `http://169.254.169.254`, so AWS SDKs and CLI tools can use the normal IMDSv2
  provider chain without an endpoint override.
- Start additional local endpoints at `127.0.0.1:<port>` for explicit profile
  selection and compatibility with tools that support a custom metadata URL.
- Create, stop, inspect, and persist IMDS endpoint definitions independently of
  AWS profile files.
- Keep IAM Identity Center tokens and temporary role credentials in the macOS
  Keychain.

## How IMDS Works

Quorra's default endpoint works at the standard EC2 metadata URL:

```text
http://169.254.169.254
```

The app remains sandboxed. A narrowly scoped macOS Network Extension forwards
only outbound TCP traffic for `169.254.169.254:80` to Quorra's private
`127.0.0.1:7114` backend. macOS separately approves installation of the system
extension and activation of its network functionality. Both approvals persist
across normal endpoint restarts and app relaunches. An extension update or a
reset of system network settings may cause macOS to request approval again.

If Quorra remains on **Waiting for approval**, use its **Open Login Items &
Extensions** button. Open Quorra's entry under **Extensions** and confirm its
Network Extension is on. Also confirm Quorra is running from `/Applications`.
If macOS reports that a restart is required, restart before enabling the
endpoint again.

Additional endpoints listen only on `127.0.0.1`. Point a compatible client to
one of those endpoints when you want an explicit custom endpoint:

```sh
export AWS_EC2_METADATA_SERVICE_ENDPOINT=http://127.0.0.1:9678
```

The profile detail view can copy this command for a running endpoint. Quorra
also publishes the active port at
`~/Library/Application Support/Quorra/imds.port` for local scripts.

## Data And Permissions

- Quorra asks you to choose the AWS folder it may access. On a normal setup,
  this is `~/.aws`.
- IAM Identity Center tokens and temporary role credentials are stored in the
  macOS Keychain, not in Quorra's application files.
- IMDS backends are limited to `127.0.0.1`; they are not exposed on your local
  network. The default endpoint is reachable through the exact
  `169.254.169.254:80` Network Extension rule.
- Quorra asks macOS to approve its narrowly scoped network configuration the
  first time the default endpoint is enabled.
- Read Only mode prevents Quorra from writing to the AWS files you selected.

## Uninstall

Turn off Quorra's default endpoint before uninstalling to remove its transparent
proxy configuration. Then quit Quorra and move `Quorra.app` from
`/Applications` to Trash. macOS removes the system extension with its containing
app and may ask you to confirm that removal. The switch in Login Items &
Extensions disables the extension but does not uninstall it.

## Development

The app is built with SwiftUI and targets macOS 26. Run all tests in Xcode with
Command-U. The local `AWSConfigINI` Swift package provides the parser and
atomic writer used for AWS shared-config files.

For release build, signing, notarization, and DMG details, see
[Distribution](docs/Distribution.md). Parser and encoder documentation is in
[AWSConfigINI](docs/AWSConfigINI.html).

## License

Quorra is available under the [Apache License 2.0](LICENSE).

Third-party package notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
