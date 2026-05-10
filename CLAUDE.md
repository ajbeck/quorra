# Quorra

Quorra is a macOS app (and companion Swift CLI) for managing AWS credentials on a developer machine. It covers four interconnected concerns:

1. **AWS Config file management** — https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.md
2. **AWS IMDS endpoint** — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.md
3. **Keychain storage** — persist sensitive credential material in the macOS Keychain; the config files hold only non-sensitive metadata, secrets live in the Keychain
4. **Swift CLI tool** (`quorra-cli`) — a companion binary other apps and shell profiles can invoke; the primary integration point is the AWS `credential_process` config key

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

## Rules

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

### References

- https://docs.aws.amazon.com/sdkref/latest/guide/feature-imds-credentials.md
- https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instancedata-data-retrieval.md

## SSO Flow

Quorra implements the **full SSO OIDC device-code flow natively** — it does not shell out to `aws sso login`. The point of the tool is to own this flow.

- Register OIDC client → start device authorization → open browser to verification URL → poll `/token` endpoint for access token → persist to macOS Keychain
- Refresh tokens when present; re-run device flow when refresh fails or isn't available
- Implementation lives in the app

## AWS Configuration File Model

Read https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.md for details.

### INI Parser

Swift Foundation has no INI parser. Generic Swift packages do not handle the AWS-specific quirks (section asymmetry, indented sub-sections under `services`, comment round-trip preservation). Quorra ships its own parser modeled on `aws-sdk-go-v2/internal/ini`.

## Keychain Storage

Sensitive values (`aws_access_key_id`, `aws_secret_access_key`, `aws_session_token`) are stored in the macOS Keychain, not in `~/.aws/credentials` in plaintext. The credentials file may contain only non-sensitive metadata, or be managed entirely by Quorra.

- Use `Security` framework: `SecItemAdd`, `SecItemCopyMatching`, `SecItemUpdate`, `SecItemDelete`
- Keychain item `service` attribute: use a stable identifier like `dev.ajbeck.quorra.aws-credentials`
- Keychain item `account` attribute: profile name
- Access group / accessibility: `kSecAttrAccessibleWhenUnlocked` minimum

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

## SwiftUI Conventions

- Use `@Observable` (Swift 5.9 macro) not `ObservableObject`/`@Published` for view models
- Views are structs in their own files, named after the view
- Previews required for all `View` types
- macOS 14+ minimum target (enables `@Observable`, `NavigationSplitView`, etc.)
- No third-party UI libraries — AppKit bridging via `NSViewRepresentable` only when SwiftUI has no equivalent
