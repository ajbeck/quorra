# Quorra

A macOS app for managing AWS credentials on a developer machine.

Quorra owns three interconnected concerns:

1. **AWS shared-config files** — `~/.aws/config` and `~/.aws/credentials`
2. **AWS Instance Metadata Service (IMDS) emulator** — serves credentials at the well-known endpoint
3. **macOS Keychain** for sensitive credential material

The point of the tool: own the full SSO OIDC device-code flow natively (no shelling out to `aws sso login`), serve credentials through a local IMDS endpoint, and edit profile files through a typed UI rather than a text editor.

---

## Status

**v1 in active development on the `getting-started` branch.** The first complete iteration — the **Config Editor** — landed on 2026-05-12. The app now boots into a real two-column UI that reads, browses, and edits profiles in `~/.aws/config` and `~/.aws/credentials`.

See the [archived implementation plan](docs/archived/ConfigEditorPlan.html) for the design decisions and acceptance walk-through. The [AWSConfigINI package documentation](docs/AWSConfigINI.html) is the authoritative reference for the parser/encoder layer.

---

## What's built

### App

- **Setup flow** — first-launch picker for `~/.aws` (or any folder) with a security-scoped bookmark; mode card to pick **Edit & Manage** (default) or **Read Only**.
- **Main view** — `NavigationSplitView` two-column layout with sidebar + detail panes. Default window size 960×640 with a content-minimum resize floor.
- **Sidebar grammar** — three sections following Apple's HIG outline pattern:
  - **SSO Sessions** as outline parents (selectable, disclosable) containing their rooted profiles
  - **Long-term keys** as a flat list of profiles holding `aws_access_key_id`
  - **Other** for role-assumption / `credential_process` profiles
- **Detail panes**
  - **Profile** detail: typed `Form` with Identity, SSO link (with cross-link button), Role, and Credential Process sections
  - **SSO session** detail: Identity (start URL / region) + Scopes (comma-joined) + status placeholder
  - **Edit & Manage** mode renders editable `TextField`/`Picker` controls; **Read Only** mode renders `LabeledContent` with a lock-icon banner that opens Settings
  - Toolbar **Save** / **Discard** in `.confirmationAction` / `.cancellationAction` placements; `⌘↩` saves
  - `navigationSubtitle("Edited")` indicates unsaved changes
  - Save errors surface as a typed `LocalizedError` alert with a Retry action
- **Settings scene** — standard macOS preferences window reachable via `⌘,`. Two tabs:
  - **General** — folder row + mode `Picker(.radioGroup)` + descriptive blurb
  - **About** — app icon, name, version (`Version 1.0 (build 1)`)
  - Mode-flip with unsaved changes shows a `confirmationDialog` with **Discard & Switch** / **Cancel**
- **Save round-trip** — writes route through `AWSConfigINIDocument.update(at:flavor:_:)` for fcntl-locked atomic rename. The `# Managed by Quorra` header is prepended on first save and idempotent on subsequent saves.

### Package — `AWSConfigINI`

Lives at `Packages/QuorraCore` as a local SwiftPM library. Implements:

- A complete INI parser with parser parity against the AWS Go SDK reference parser (handles `[default]` vs `[profile foo]` vs `[foo]`, sub-property maps under `services`, BOM detection, comment round-trip)
- Editing through value-typed `AWSConfigINIDocument` / `Section` / `Key` with deterministic write order
- fcntl advisory lock + atomic rename for cross-process safety
- A `Codable` layer with three opinionated structs: `Profile`, `SSOSession`, `ServicesEntry`
- Typed throws via `AWSConfigINIError: LocalizedError`
- Fully tested in-package; the app consumes the library product

---

## What's planned

In rough priority order. Each is a candidate for its own implementation plan in `docs/` once it's the next thing.

- **SSO OIDC device-code flow** — register OIDC client → device authorization → browser → poll `/token` → persist to Keychain → refresh on expiry
- **Keychain wiring** — store `aws_access_key_id` / `aws_secret_access_key` / `aws_session_token` outside the plaintext credentials file
- **Local IMDS emulator** — bind to `127.0.0.1:<port>`, IMDSv2 by default with v1 fallback, publish port at `~/Library/Application Support/Quorra/imds.port` for consumer discovery
- **Credentials tab** in the profile detail pane (depends on Keychain wiring)
- **Activity tab** + an event log (request log from the IMDS server, SSO refresh events, save events)
- **Add Profile / Delete Profile / Search** in the sidebar
- **FSEvents file watching** — auto-refresh the sidebar when another process changes the AWS files
- **Profile rename** (currently the section header isn't editable from the form)
- **Region / source-profile / session autocomplete** in the editor
- **Window-close confirmation** when an editor pane is dirty (uses the existing `EditorState.dirtyDescription`)

---

## Tech stack

- **Language**: Swift 6.2
- **UI**: SwiftUI (macOS only)
- **Minimum macOS**: macOS 26 (Tahoe) — personal-tool floor; we use the newest APIs without compatibility gymnastics
- **State management**: `@Observable` / `@State` (Swift Observation framework, not `ObservableObject`)
- **Persistence**: macOS Keychain for secrets (Security framework); `UserDefaults.standard` for non-secret app config; security-scoped bookmark for `~/.aws` access; direct file I/O for the AWS files
- **Testing**: Swift Testing (`@Test` macro)

---

## Distribution

Initially **Homebrew Cask** distributing `Quorra.app`. App Store distribution is the long-term target — the build is configured today for App Store constraints: sandbox, hardened runtime, and identifier-based signing.

---

## Repo layout

```
App/                              SwiftUI app sources
  Root/                           AppModel, AppPhase, AppError, RootView
  Bookmarks/                      BookmarkStorage, FolderPicker, UserHome
  Preferences/                    ModePreferenceStorage
  Profiles/                       ProfilesModel, EditorState, Sidebar* / Profile* / Session* nodes
  Theme/                          Theme.swift (color tokens)
  Views/
    Setup/                        — SetupView lives at Views/SetupView.swift
    Settings/                     SettingsView, GeneralSettingsTab, AboutSettingsTab
    Detail/                       ProfileDetailView, SessionDetailView, OptionalStringBinding
    SidebarRows/                  SessionRow, ProfileRow
    SetupView, ErrorView, MainView, SidebarView, DetailView
  Assets.xcassets/                AppIcon, AccentColor
  quorraApp.swift                 @main entry point

Packages/QuorraCore/              local SwiftPM package
  Sources/AWSConfigINI/           parser, encoder, fcntl-locked atomic write
  Tests/AWSConfigINITests/        Swift Testing

Tests/QuorraAppTests/             app-level tests
                                  (target name: quorraTests)

Configs/                          entitlements files
docs/                             AWSConfigINI.html (live) + archived/ plans
```

---

## Quick start

Open the workspace and ⌘R:

```sh
open Quorra.xcworkspace
```

Reset to first-launch state (Apple's documented approach):

```sh
rm -rf ~/Library/Containers/dev.ajbeck.quorra
```

Tests:

```sh
# from Xcode: ⌘U on the quorra scheme
# Both targets — quorraTests and AWSConfigINITests — run together.
```

---

## License

TBD.
