# Quorra

Quorra is a macOS app (and companion Swift CLI) for managing AWS credentials on a developer machine. It covers four interconnected concerns:

1. **Config file management** — read/write `~/.aws/config` and `~/.aws/credentials`
2. **IMDS endpoint** — host a local EC2 Instance Metadata Service-compatible HTTP endpoint so that other processes on the machine can obtain credentials as if they were running on EC2
3. **Keychain storage** — persist sensitive credential material in the macOS Keychain; the config files hold only non-sensitive metadata, secrets live in the Keychain
4. **Swift CLI tool** (`quorra-cli`) — a companion binary other apps and shell profiles can invoke; the primary integration point is the AWS `credential_process` config key

## Prior Art: Ludwig

`/Users/aj.beck/Developer/repos/smartpension/ludwig` is a Go CLI covering overlapping scope. Read it when designing new features — it's the closest reference we have.

**What Ludwig does that we should mirror:**

- Clean separation of data model: `AWSProfile`, `CredentialProfile`, `SSOSession`, `SSOCachedToken`
- Load config and credentials files independently, merge by profile name
- Round-trip preservation: read-modify-write never loses unknown sections or fields
- SSO token cache at `~/.aws/sso/cache/{sha1(session_name)}.json`, JSON body, 0600 perms
- `active_profile` concept — a file storing the currently active profile name
- Filesystem abstraction for in-memory testing (in Go: `afero.Fs`; in Swift: define a `FileSystem` protocol)
- Full SSO OIDC device-code flow: register client → start device auth → poll for token → refresh when expired

**Where Quorra diverges (our differentiators):**

- **Keychain, not plaintext.** Ludwig writes credentials to `~/.aws/credentials` in plaintext (0600). Quorra stores secrets in the macOS Keychain; the credentials file is either managed by Quorra to be empty of secrets or omitted entirely.
- **Local IMDS server.** Ludwig has none — it relies on the AWS SDK's own IMDS client. Quorra runs a real local HTTP server so tools with `credential_source = Ec2InstanceMetadata` or `AWS_EC2_METADATA_SERVICE_ENDPOINT` can point at it.
- **`credential_process` implementation.** Ludwig doesn't implement it. Quorra's CLI is the intended `credential_process` target.
- **File locking.** Ludwig relies on OS atomicity for writes; no cross-process locking. Quorra should use `flock`/`fcntl` advisory locks on config/credentials files since the CLI and app may both write.

## Project Structure

```
quorra/                     SwiftUI macOS app target
quorra-cli/                 Swift CLI tool target (not yet scaffolded)
quorra.xcodeproj/           Xcode project
```

## Tech Stack

- **Language**: Swift (current toolchain)
- **UI**: SwiftUI (macOS only)
- **Minimum macOS target**: macOS 26 (Tahoe). This is a personal developer tool, not a broad-distribution product; we take the current OS as the floor to use the newest APIs without compatibility gymnastics.
- **State management**: `@Observable` / `@State` (Swift Observation framework, not the older `ObservableObject`/`@Published`)
- **Persistence**: macOS Keychain (`Security` framework) for secrets; direct file I/O for `~/.aws/` files
- **Xcode MCP server**: use `mcp__xcode__*` tools for build, diagnostics, preview, grep, file ops — prefer these over raw `bash` for anything touching the Xcode project

## Bundle Identifier

`dev.ajbeck.quorra` is the app's bundle identifier. Keychain access groups and the sandbox container path are derived from this.

## Setup Flow (First Launch)

On first launch the app has no security-scoped bookmark yet, so it shows `SetupView`. After the user picks their AWS folder, it persists the bookmark and swaps to `MainView`. On subsequent launches it resolves the stored bookmark and goes straight to `MainView`.

- **What the user picks:** the `~/.aws` folder (a single folder, not individual files). Sandbox access extends to everything inside, including files created later (important for `~/.aws/sso/cache/*.json` which are generated at runtime).
- **Picker:** `NSOpenPanel` directly (not SwiftUI's `fileImporter`) so we can set `showsHiddenFiles = true`. Pre-fills `directoryURL = ~/.aws`. Presented via `withCheckedContinuation` around `panel.begin { ... }` — non-blocking, `async`-compatible.
- **Non-standard folder handling:** accept any folder the user picks. If it's not `~/.aws`, show a non-blocking warning about `AWS_CONFIG_FILE` before persisting the bookmark.
- **Bookmark storage:** `UserDefaults.standard` under key `dev.ajbeck.quorra.awsFolderBookmark`. Pure helper type `BookmarkStorage` owns the save/load/resolve plumbing (stateless, no SwiftUI dependency).
- **Security-scope lifetime:** resolve + `startAccessingSecurityScopedResource()` once at launch, hold for app lifetime. Matches "this app is authorised to read the user's AWS folder" semantically.

## App Architecture (current)

```
quorra/
  quorraApp.swift             @main; @State AppModel; .environment injection
  App/
    AppModel.swift            @Observable; owns phase; async transition methods
    AppPhase.swift            enum: .setup / .ready(URL) / .error(AppError)
    AppError.swift            enum: bookmarkResolutionFailed / folderAccessDenied / folderMissing
    RootView.swift            switches on appModel.phase; runs .task at launch
  Bookmarks/
    BookmarkStorage.swift     pure load/save/resolve helpers (UserDefaults backed)
    FolderPicker.swift        NSOpenPanel wrapper; async via withCheckedContinuation
  Views/
    SetupView.swift           .setup phase
    MainView.swift            .ready phase; hosts FolderContentsView
    FolderContentsView.swift  directory listing for the bookmarked folder
    ErrorView.swift           .error phase
```

Rules:

- `AppModel` methods are the only way to mutate `phase` — `phase` is `private(set)`. Methods: `resolveStoredBookmark()`, `completeSetup(selectedFolder:)`, `resetToSetup()`. All `async`.
- Views read model via `@Environment(AppModel.self)`. No prop-drilling.
- `SetupView` orchestrates the picker: calls `FolderPicker.pickAWSFolder()`, then `appModel.completeSetup(selectedFolder:)`. View drives; model stores.
- `BookmarkStorage` has no SwiftUI dependency and is the primary test target for v1.
- Every view file ships with at least one `#Preview`. Use named previews for different states (e.g. `#Preview("Setup")`, `#Preview("Error – folderMissing")`).

## Sandbox & Dev Loop

App is sandboxed. This is locked in — Mac App Store distribution is the long-term target and sandboxing is an App Store requirement. Access to `~/.aws` is granted via the security-scoped bookmark chosen in `SetupView`.

**Reset to clean state** (Apple's documented approach for testing first-launch behaviour):

```
rm -rf ~/Library/Containers/dev.ajbeck.quorra
```

Relaunch the app afterwards — macOS recreates the container empty. This clears UserDefaults (including the bookmark), Application Support, Caches — everything the sandboxed app has written. **Does not clear Keychain items** (Keychain is system-scoped). When we add Keychain usage, a companion reset command will be needed.

No macOS Simulator exists. Apps run natively via ⌘R in Xcode. Use SwiftUI `#Preview` for iterating on view code without launching the app.

## Testing

`quorraTests` target uses **Swift Testing** (`@Test` macro), not XCTest. Swift Testing is the default for Xcode 16+ projects and is the forward-looking choice. XCTest stays for UI tests if we ever add them.

First test target is `BookmarkStorage` — round-trip save/load, missing-key handling, malformed-data handling. Tests inject a `UserDefaults(suiteName:)` to avoid polluting real defaults.

## App ↔ CLI Architecture

The app (`quorra.app`) and the CLI (`quorra-cli`) are **independent binaries**. They do not share a process, do not speak over XPC, and do not share a Unix socket. The **only** surface they share is a **Keychain access group**, which both targets are entitled to read and write.

Implications:

- Any mutation of AWS config/credentials files, Keychain items, or SSO tokens may happen from either binary. Both must treat the filesystem and Keychain as shared mutable state and use file locks (`flock`/`fcntl`) for concurrent safety.
- When the CLI needs user interaction (e.g. SSO login, MFA prompt) the CLI drives it itself — it does not hand off to the running app. This keeps the CLI independently usable even when the app is not running.
- Both targets must be code-signed with the same Team ID and declare a shared `keychain-access-groups` entitlement (e.g. `$(TeamIdentifierPrefix)dev.ajbeck.quorra.shared`).

## Local IMDS Server

Quorra binds the IMDS server to **`127.0.0.1:<port>`** (not the real link-local `169.254.169.254`). This avoids needing a loopback alias or elevated privileges, at the cost of requiring consumers to set `AWS_EC2_METADATA_SERVICE_ENDPOINT=http://127.0.0.1:<port>` in their shell.

- **IMDSv2 by default**, IMDSv1 supported as a fallback.
- **IMDSv2 flow:** client does `PUT /latest/api/token` with header `X-aws-ec2-metadata-token-ttl-seconds: <n>`, server returns a token string; subsequent `GET /latest/meta-data/...` requests must include header `X-aws-ec2-metadata-token: <token>`.
- **IMDSv1 flow:** plain `GET /latest/meta-data/...` with no token. Quorra responds to these too, but can surface a setting to reject them.
- **Credentials path:** `GET /latest/meta-data/iam/security-credentials/` returns the role name as plain text; `GET /latest/meta-data/iam/security-credentials/<role-name>` returns the JSON credential document with `Code: "Success"`, `Type: "AWS-HMAC"`, `AccessKeyId`, `SecretAccessKey`, `Token`, `Expiration`.
- The app publishes the port at a well-known location (e.g. a file under `~/Library/Application Support/Quorra/imds.port`) so the CLI and helper scripts can discover it.

## SSO Flow

Quorra implements the **full SSO OIDC device-code flow natively** — it does not shell out to `aws sso login`. The point of the tool is to own this flow.

- Register OIDC client → start device authorization → open browser to verification URL → poll `/token` endpoint for access token → persist to `~/.aws/sso/cache/{sha1(session_name)}.json` (the same location the AWS SDKs read from, for compatibility)
- Refresh tokens when present; re-run device flow when refresh fails or isn't available
- Implementation lives in the app; the CLI invokes it via… TBD. Since app↔CLI don't talk directly, either (a) the CLI runs its own device-code flow using the same code, or (b) both write/read the same SSO cache files and the CLI surfaces "run `quorra login` first" when the cache is missing/expired.

## AWS Configuration File Model

### Files

| File                 | Purpose                                                                                    | Default location                                                                 |
| -------------------- | ------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------- |
| `~/.aws/config`      | Non-sensitive settings: region, output format, role ARNs, SSO config, `credential_process` | `$HOME/.aws/config` — override with `AWS_CONFIG_FILE` env var                  |
| `~/.aws/credentials` | Sensitive: access key ID, secret key, session token                                        | `$HOME/.aws/credentials` — override with `AWS_SHARED_CREDENTIALS_FILE` env var |

Both files can be relocated via environment variables. Quorra must respect these env vars when resolving file paths.

### INI Format Rules

- Section headers in brackets: `[default]`, `[profile dev]`, `[sso-session my-sso]`, `[services my-services]`
- **Critical asymmetry**: in `config` non-default profiles use `[profile name]`; in `credentials` they use `[name]` (no "profile" prefix). The default profile is `[default]` in both files.
- Key-value pairs: `key = value` or `key=value`
- Comments: lines starting with `#`
- Credentials file keys take precedence over config file keys for the same profile name

### Section Types

**`profile`** — the main unit. Quorra manages these. Key fields:

| Key                     | File                              | Purpose                                                 |
| ----------------------- | --------------------------------- | ------------------------------------------------------- |
| `aws_access_key_id`     | credentials (preferred) or config | Long-term or short-term access key                      |
| `aws_secret_access_key` | credentials (preferred) or config | Secret key                                              |
| `aws_session_token`     | credentials (preferred) or config | Required for short-term/STS credentials                 |
| `region`                | config                            | Default AWS region for this profile                     |
| `output`                | config                            | Default output format                                   |
| `role_arn`              | config                            | ARN of role to assume                                   |
| `source_profile`        | config                            | Profile supplying base credentials for role assumption  |
| `credential_source`     | config                            | `Ec2InstanceMetadata`, `Environment`, or `EcsContainer` |
| `credential_process`    | config                            | Path to external binary that returns credentials JSON   |
| `sso_session`           | config                            | References an `[sso-session name]` section              |
| `sso_account_id`        | config                            | AWS account ID for SSO                                  |
| `sso_role_name`         | config                            | IAM role name for SSO                                   |
| `mfa_serial`            | config                            | ARN or serial of MFA device                             |
| `duration_seconds`      | config                            | Role session duration (900–43200, default 3600)       |
| `role_session_name`     | config                            | Session name for assumed role                           |

**`sso-session`** — groups SSO token acquisition settings:

- `sso_start_url` (required), `sso_region` (required), `sso_registration_scopes`
- Tokens cached in `~/.aws/sso/cache/` with filename derived from session name

**`services`** — custom endpoint overrides per service; linked from a profile via `services = name`. Uses an indented sub-key syntax that generic INI parsers do not handle:

```
[services my-services]
dynamodb =
  endpoint_url = http://localhost:8000
  region = us-east-1
s3 =
  endpoint_url = http://localhost:9000
```

### INI Parser

Swift Foundation has no INI parser. Generic Swift packages do not handle the AWS-specific quirks (section asymmetry, indented sub-sections under `services`, comment round-trip preservation). Quorra ships its own parser modeled on `aws-sdk-go-v2/internal/ini`.

**Module: `AWSConfigINI`** (target lives in the main app and is also linked by the CLI)

```
AWSConfigINI/
  Lexer.swift     — tokenize lines into Section, KeyValue, Comment, Blank, Continuation
  Parser.swift    — build a SectionedDocument preserving order, comments, raw whitespace
  Writer.swift    — round-trip back to text without losing user formatting
  Model.swift     — typed accessors: AWSProfile, SSOSession, ServicesSection, etc.
  Tests/          — round-trip tests against real-world config samples
```

Requirements:

- Preserve comments and blank lines on read-modify-write
- Preserve unknown keys and unknown section types
- Handle the `[profile foo]` (config) vs `[foo]` (credentials) asymmetry at the Model layer, not the Parser layer — the parser stays dumb and faithful to the file
- Handle `services` indented sub-sections
- Accept both `key=value` and `key = value`
- Treat lines starting with `#` or `;` as comments

### Credential Types Quorra Must Handle

1. **Long-term IAM** — `aws_access_key_id` + `aws_secret_access_key`
2. **Short-term/STS** — above + `aws_session_token`
3. **IAM role assumption** — `role_arn` + `source_profile` (or `credential_source`)
4. **SSO / IAM Identity Center** — `sso_session` reference; token in `~/.aws/sso/cache/`
5. **External process** — `credential_process = /path/to/quorra-cli ...`
6. **EC2 Instance Metadata** — `credential_source = Ec2InstanceMetadata` (Quorra hosts the local endpoint for this)

## IMDS Endpoint

The EC2 Instance Metadata Service normally lives at `http://169.254.169.254` on real EC2 instances. On a developer machine, Quorra runs a local HTTP server that speaks the same IMDS API so that tools using `credential_source = Ec2InstanceMetadata` work locally.

- The IMDS credentials path is `http://169.254.169.254/latest/meta-data/iam/security-credentials/<role-name>`
- Response format: JSON with `AccessKeyId`, `SecretAccessKey`, `Token`, `Expiration`, `Code: "Success"`, `Type: "AWS-HMAC"`
- AWS SDKs and CLI also respect `AWS_EC2_METADATA_SERVICE_ENDPOINT` env var to redirect IMDS calls to a custom address — Quorra may use this to point tools at the local server without requiring binding to the link-local address

## Keychain Storage

Sensitive values (`aws_access_key_id`, `aws_secret_access_key`, `aws_session_token`) are stored in the macOS Keychain, not in `~/.aws/credentials` in plaintext. The credentials file may contain only non-sensitive metadata, or be managed entirely by Quorra.

- Use `Security` framework: `SecItemAdd`, `SecItemCopyMatching`, `SecItemUpdate`, `SecItemDelete`
- Keychain item `service` attribute: use a stable identifier like `dev.ajbeck.quorra.aws-credentials`
- Keychain item `account` attribute: profile name
- Access group / accessibility: `kSecAttrAccessibleWhenUnlocked` minimum

## Swift CLI Tool (`quorra-cli`)

The CLI is the integration surface for external tools. Its primary role is implementing the `credential_process` contract:

```
# In ~/.aws/config
[profile my-profile]
credential_process = /usr/local/bin/quorra-cli credentials --profile my-profile
```

**Required JSON output for `credential_process`:**

```json
{
  "Version": 1,
  "AccessKeyId": "ASIA...",
  "SecretAccessKey": "...",
  "SessionToken": "...",
  "Expiration": "2026-05-07T12:00:00Z"
}
```

- `SessionToken` and `Expiration` are omitted for long-term credentials
- The CLI retrieves secrets from the Keychain (not from plaintext files)
- The CLI communicates with the running Quorra.app via XPC or a local socket for operations that require user interaction (e.g., SSO login, MFA prompt)

## Development Workflow

### Building

Use the Xcode MCP server:

```
mcp__xcode__BuildProject  — build the project
mcp__xcode__GetBuildLog   — inspect build output
mcp__xcode__XcodeListNavigatorIssues — see errors/warnings
mcp__xcode__RenderPreview — render SwiftUI previews
mcp__xcode__RunAllTests / RunSomeTests — run tests
```

### File operations within the Xcode project

Prefer `mcp__xcode__XcodeRead`, `mcp__xcode__XcodeWrite`, `mcp__xcode__XcodeLS`, `mcp__xcode__XcodeGrep`, `mcp__xcode__XcodeMV`, `mcp__xcode__XcodeRM` over raw filesystem tools — these keep the Xcode project index in sync.

### Current Xcode workspace

Tab identifier: `windowtab1`
Workspace path: `/Users/aj.beck/Developer/repos/ajbeck/quorra/quorra.xcodeproj`

## SwiftUI Conventions

- Use `@Observable` (Swift 5.9 macro) not `ObservableObject`/`@Published` for view models
- Views are structs in their own files, named after the view
- Previews required for all `View` types
- macOS 14+ minimum target (enables `@Observable`, `NavigationSplitView`, etc.)
- No third-party UI libraries — AppKit bridging via `NSViewRepresentable` only when SwiftUI has no equivalent
