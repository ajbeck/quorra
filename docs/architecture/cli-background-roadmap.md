# CLI and Background App Roadmap

This document is the durable design graph and decision log for Quorra's CLI,
menu-bar, background lifecycle, and IPC work. Update it whenever scope, status,
or a decision changes.

## Evidence Policy

Before surfacing an Apple-platform design question or decision, inspect the
relevant repository and project state through the Xcode MCP connected to Xcode
27 beta. Use its documentation search when available; when that capability is
not exposed, consult only official Apple Developer documentation as the
fallback. Record conclusions and their supporting evidence here.

## Design Graph

```text
Shared non-UI services
├── profile discovery and loading
├── version information
└── IMDS lifecycle boundary
    ├── read-only CLI
    │   ├── quorra version
    │   ├── quorra profiles list
    │   └── signed CLI distribution
    │       ├── embed in quorra.app
    │       ├── Settings install/remove flow
    │       └── stable command link to embedded executable
    └── background app lifecycle
        ├── menu-bar interface
        ├── Dock visibility and window behavior
        ├── endpoint restoration
        └── launch-at-login policy
            └── versioned IPC
                └── operational CLI commands
                    ├── profiles sign-in
                    ├── imds list/status
                    ├── imds start/stop
                    ├── imds switch-profile
                    └── explicit app start/stop
```

## Delivery Status

| Stage | Status | Exit condition |
| --- | --- | --- |
| Shared profile loader | Complete | App and CLI consume one tested loader |
| Read-only CLI | Complete | Version/profile commands, Settings installation, and Release packaging pass |
| Menu-bar/background mode | Complete | Signed-app login launch, menu-only operation, and notification cold-open pass |
| Versioned IPC | Complete | Signed local client can query/control the running app |
| Operational CLI | Complete | Authenticated sign-in and IMDS/app lifecycle commands pass end to end |

## Decisions

### D001 — CLI packaging

**Decision:** Add an internal SwiftPM executable product named `quorra-cli` to
`Packages/QuorraCore`, backed by a shared `QuorraCLIKit` library and thin SwiftPM
and Xcode launchers. The installed command and Argument Parser root remain
`quorra`. `QuorraCLIKit` directly depends on Apple Swift Argument Parser.

**Evidence:** Reusable Quorra logic and tests already live in this package.
ArgumentParser documents an executable target with a direct product dependency.
The resolved graph currently contains ArgumentParser only transitively. Using a
distinct internal product name keeps the installed command independent of its
build product. The app's shared scheme is explicitly named `QuorraApp`, so it
cannot collide with SwiftPM-generated command schemes in the workspace.

### D002 — Profile loading boundary

**Decision:** Extract parsing, discovery, and loading into a dedicated,
lightweight `QuorraProfiles` module. Keep `ProfilesModel` as the main-actor
observable adapter used by the app. The CLI depends on `QuorraProfiles`, not
`QuorraAppLogic`.

**Evidence:** Parsing and grouping are already nonisolated and run in a detached
task, but filesystem loading was private to `ProfilesModel`. A cold CLI build
now compiles only ArgumentParser, `AWSConfigINI`, `QuorraProfiles`, and the CLI
target rather than the AWS client runtime.

### D003 — AWS SDK dependency boundary

**Decision:** Remove the unused `AWSSSO` product. Retain `AWSSSOOIDC` in
`IAMIdentityCenter` for the initial CLI slice; reassess replacing its four OIDC
operations with a focused `URLSession` client as separate work.

**Evidence:** Production code imports only `AWSSSOOIDC`. SwiftPM resolves and
checks out dependencies at package granularity, while compiling the selected
product's reachable target graph. Keeping the CLI outside `IAMIdentityCenter`
avoids compiling Smithy/AWS runtime targets, although SwiftPM still resolves the
repository because it remains a top-level `QuorraCore` package dependency.

### D004 — Profile-list interface

**Decision:** Resolve paths in the order explicit option, AWS environment
variable, then `~/.aws`. Support `table`, `names`, and `json` output. JSON is the
first automation contract and contains profile metadata, never credentials.

### D005 — One Quorra release version

**Decision:** The app, CLI, background lifecycle, and future IPC implementation
share one Quorra release version. Release Please manages one root component and
updates both `version.txt` and the compiled CLI version constant in the same
release pull request. A test enforces that they match.

**Evidence:** The app archive already receives the root release version as
`MARKETING_VERSION`. Release Please's manifest configuration preserves the
existing simple release strategy and root outputs while its generic updater can
synchronize the Swift source. Future IPC messages may carry an internal protocol
compatibility number, but that number is not a separately released product
version.

### D006 — CLI distribution and updates

**Decision:** Build the CLI as a separately signed, hardened executable and
embed it in the Quorra app bundle rather than publishing an independently
versioned download. Settings will provide setup and removal actions for a
stable command link to the embedded executable. Sparkle replaces the app bundle,
so an installed link continues to execute the CLI shipped by the current app.

The embedded executable is
`Contents/Helpers/QuorraCLI.app/Contents/MacOS/quorra-cli`. The helper app gives
the CLI its own signed identity and App Group entitlement while remaining an
`LSBackgroundOnly` implementation detail. The installed, user-facing command is
`quorra`. Settings recommends `~/.local/bin`, but the user explicitly chooses
the destination folder and Quorra persists that access with a security-scoped
bookmark.

**Evidence:** Apple requires every distributed executable to have a valid
Developer ID signature and hardened runtime. Apple also supports embedding a
separately signed command-line executable as nested app code. Keeping the binary
inside the app preserves Quorra's single release version and prevents the app
and CLI from drifting after an update.

**Implementation backlog:**

- Produce a universal Release helper app with its own signing identifier,
  Developer ID signature, secure timestamp, hardened runtime, and App Group.
- Embed the CLI at a stable path in `quorra.app` and verify nested signatures in
  the release workflow before notarization.
- Ensure the terminal-launched CLI can read the user's AWS configuration without
  inheriting the GUI app's sandbox restrictions.
- Add Settings UI for install, repair, status, and uninstall. Never overwrite an
  unrelated executable at the chosen command path.
- Prefer a no-admin user command directory; explain PATH setup when required.
  Evaluate an authenticated `/usr/local/bin` installation only as a deliberate
  follow-up.
- Verify that Sparkle updates preserve the command link and immediately expose
  the new CLI version.
- Add tests for missing/moved apps, stale or conflicting links, permissions, and
  rollback behavior.

**Implemented:** The native CLI target is embedded as signed nested code, and
General Settings now provides install, repair, conflict, access-loss, and
uninstall states. Link mutations are ownership-checked and covered by focused
filesystem tests. Apple documents `NSOpenPanel` as extending sandbox access to
the selected folder and security-scoped bookmarks as the mechanism for restoring
that access. The superseded raw Xcode CLI target has been removed after archive
validation; the SwiftPM launcher remains for development. The signed Debug app
successfully installed, executed, and removed the command in `~/.local/bin`;
Release archive validation remains.

### D007 — Process-scoped runtime and menu bar

**Decision:** Long-lived profile, credential, notification, and Default IMDS
Endpoint work belongs to `AppRuntimeCoordinator`, owned by the application
delegate. SwiftUI windows consume that runtime but do not own it. Quorra exposes
an always-present `MenuBarExtra` while the process is running.

**Evidence:** The previous startup and endpoint-restoration tasks were attached
to `RootView` and `MainView`, so closing their windows cancelled behavior that a
background app must retain. A bound optional menu extra triggered a continuous
SwiftUI app-graph rebuild in Xcode 27 beta; using the built-in, always-present
extra eliminated the loop and returned the idle debug process to 0% CPU.

### D008 — Background presentation and launch at login

**Decision:** Keep background presentation and login registration as separate
user choices. “Run in the menu bar only” uses AppKit's `.accessory` activation
policy and suppresses/restoration-disables the main SwiftUI scene. “Launch
Quorra at login” registers `SMAppService.mainApp`. If macOS requires approval,
Settings explains the state and links to Login Items.

**Evidence:** Apple documents `.accessory` as hiding the Dock and application
menu while retaining programmatic activation and windows. SwiftUI's suppressed
launch behavior avoids presenting the scene when no state is restored, and
disabled restoration prevents a window from unexpectedly returning. Apple
documents `SMAppService.mainApp` as the supported way to launch the same main
application on subsequent logins; no helper target is needed.

### D009 — Notification navigation from background state

**Decision:** Route notification clicks through the navigation-only URL
`quorra://open/imds/default`. The main `WindowGroup` claims that external event,
and its root view converts the URL into the same in-process endpoint-open request
used by the menu command. The route never changes credentials or endpoint state.

**Evidence:** Apple's `OpenWindowAction` is available through a SwiftUI view
environment, not the app delegate. Apple documents external-event matching as
the mechanism that creates a matching scene when no open scene can handle an
incoming URL. In the Xcode 27 beta runtime test, menu-bar-only Quorra initially
owned only its status-bar window; delivering the route created a visible SwiftUI
`Quorra` window while the original process remained alive.

### D010 — Menu-bar identity

**Decision:** Replace the generic antenna SF Symbol with a monochrome template
vector derived from Quorra's existing app icon: a bold Q ring and tail with one
small endpoint node. Keep runtime status inside the menu so the brand glyph
remains stable and legible at menu-bar size. SwiftUI's named-image
`MenuBarExtra` initializer preserves the `Quorra` accessibility title.

**Evidence:** The stock `q.circle` is a generic monogram, the antenna describes
only IMDS, and the key describes only credentials. The custom mark connects the
app icon's circular scanner silhouette with the Q name and remains identifiable
in a 36-pixel Retina rendering.

### D011 — Versioned local IPC

**Decision:** Use one length-prefixed JSON request and response per Unix-domain
socket connection. The sandboxed app owns `ipc-v1.sock` inside App Group
`9GEBAJV9R4.quorra`; the separately signed helper has the same entitlement.
The socket is mode `0600`, the server verifies the peer UID with `getpeereid`,
frames are capped at 1 MiB, and every request carries an independent protocol
version and UUID. Read operations time out after two seconds; credential-backed
mutations allow 30 seconds.

**Evidence:** Xcode 27 beta proved `NSXPCListenerEndpoint` cannot be archived by
`NSKeyedArchiver` because it may only be encoded by an `NSXPCCoder`; an existing
XPC connection is therefore required before that endpoint can be transferred.
Apple explicitly supports App Groups and Unix-domain sockets between sandboxed
and nonsandboxed macOS apps. The directly invoked helper can return nil from
`FileManager.containerURL`; it therefore falls back only to Apple's documented
macOS group-container path when that system-created directory already exists.
The signed Terminal-equivalent runtime test passed through the protected socket.

### D012 — Explicit CLI app lifecycle

**Decision:** Commands that require Quorra's runtime never launch the app as a
side effect. When the IPC service is unavailable they fail with an actionable
message directing the user to `quorra start`. App process control is explicit:
`quorra start` launches Quorra through Launch Services and `quorra stop` asks
the running app to terminate cleanly over IPC.

**Evidence:** IMDS operations require the app-owned runtime and socket, while
`version` and `profiles list` are intentionally standalone. Apple's
`NSWorkspace.OpenConfiguration` reuses a running app when
`createsNewApplicationInstance` is false, and `NSApplication.terminate(_:)`
runs the normal application termination path, including Quorra's IPC shutdown.

### D013 — One Quorra process per login session

**Decision:** Set `LSMultipleInstancesProhibited` on the main app. Launch
Services must reuse the running Quorra process instead of allowing installed,
Debug, or copied bundles with the same identity to create duplicate menu-bar
items and compete for the IPC socket.

**Evidence:** Xcode 27 beta exposed simultaneous Debug and `/Applications`
processes. The second process remained alive after its IPC bind failed. Apple
documents `LSMultipleInstancesProhibited` as the launch condition that rejects
a separate app instance. With the key enabled, opening a second signed copy
returned the existing process identifier and the process count remained one.

### D014 — App-owned CLI authentication

**Decision:** `quorra profiles sign-in <profile>` asks the running app to start
the existing IAM Identity Center device flow. The app resolves the profile to
its SSO session, opens Quorra's sign-in window, and performs every Keychain
write. The initial IPC request returns a UUID immediately; the CLI polls short
status requests and sends a cancellation request when interrupted. IPC exposes
only names, timestamps, state, and error prose—never tokens, verification URLs,
or role credentials. The command does not launch Quorra implicitly.

**Evidence:** `CredentialsModel` already owns the tested device flow and
`AppRuntimeCoordinator` already observes its in-flight verification state to
present `AuthBrowserPresenter`. Xcode 27 builds the shared operation coordinator
and the focused transition, failure, cancellation, parsing, and serialization
tests pass.

### D015 — Dock visibility in the menu-bar menu

**Decision:** Expose the existing presentation preference as a checked `Show
Quorra in Dock` menu item. This changes the same AppKit activation policy used
by General Settings; it does not start another process or create another menu
extra.

### D016 — Dual-toolchain pull-request validation

**Decision:** Run the complete pull-request test plan on both stable
`macos-26` and the `xcode-27` public-preview runner. Preserve the existing
stable check name for branch protection and give failed result bundles unique
matrix artifact names. Build signed releases with Xcode 27 because the native
CLI target and its signing configuration are maintained with that toolchain.

**Evidence:** GitHub lists `xcode-27` as the Apple-silicon public-preview label.
Version 3 of the release workflow's app-token action deprecates its numeric
app-ID input, so the action receives the repository's
`RELEASE_PLEASE_CLIENT_ID` value.

### D017 — Retain the AWS SDK OIDC client

**Decision:** Keep `AWSSSOOIDC` as the production implementation behind
`OIDCRequesting`. Do not replace it with a focused `URLSession` client or carry
a fork of the generated AWS package.

**Evidence:** Quorra selects only the `AWSSSOOIDC` product, but its shared
identity/runtime graph adds Smithy, the CRT, and five internal service clients;
this is principally a clean-build and archive cost. A direct client would also
have to own AWS partition endpoint rules, OAuth error compatibility, retries,
and future protocol changes. The existing SDK client is created lazily, while
the standalone CLI remains outside `IAMIdentityCenter` and therefore avoids
compiling the AWS graph.

### D018 — Developer ID signing for the embedded CLI

**Decision:** Give `QuorraCLI` explicit per-configuration signing settings:
automatic Apple Development signing for Debug and manual Developer ID signing
for Release. Keep the main app's manual provisioning profile, avoid a global
archive identity override, and verify the exported helper's authority, hardened
runtime, identifier, App Group entitlement, and nested signature in CI.

**Evidence:** A workspace-wide `CODE_SIGN_IDENTITY` override also reached Swift
package resource bundles and conflicted with the helper's automatic signing.
Its only entitlement is the macOS team-prefix App Group
`9GEBAJV9R4.quorra`; Apple documents this form as unrestricted and not requiring
a provisioning profile. `REGISTER_APP_GROUPS=NO` reflects that unprovisioned
form. The main app still requires its profile for the restricted Keychain access
group. Xcode 27 evaluates both application targets as Developer ID/manual for
Release without applying that identity to package targets.

## Open Decisions

- None for the current implementation scope.

## Recommended Pre-release Sequence

1. Split the branch into logical Conventional Commits and open the feature PR.
2. Let CI perform the Developer ID export/notarization gates unavailable
   locally, then complete a signed installed-app smoke check before publishing.

## Verification Record

- Xcode MCP workspace: `Quorra.xcworkspace` in Xcode 27.0 beta (`27A5252f`).
- The local command-line developer directory still defaults to Xcode 26.6;
  Xcode 27 beta validation therefore invokes
  `/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild`
  explicitly. GitHub's ordinary `macos-26` image has the same stable-toolchain
  boundary; its separate `xcode-27` preview label is required for beta CI.
- Fresh Xcode 27 beta full `quorra` test plan after CLI sign-in and menu changes:
  504 concrete cases passed, 0 failed, 0 skipped. Xcode's warning audit returned
  no build warnings.
- CLI command/parser and rendering suite: 14 passed, 0 failed.
- Xcode 27 beta integrated build-for-testing passed with no warnings.
- Menu-bar/background changes build without source warnings. Live
  menu-bar-only toggling passed in the debug app. With both app windows closed,
  Launch Services reported the process as `UIElement` (no Dock application)
  while the same process continued answering `quorra imds list` over IPC.
- The custom Q template asset builds without warnings and remains recognizable
  in a 36-pixel Retina rendering. In windowless menu-bar-only mode, macOS
  Accessibility identified the `QuorraMenuBarIcon` status item; clicking it
  exposed the complete endpoint, navigation, update, and quit menu.
- The bound optional menu extra reproduced a main-thread SwiftUI graph loop;
  the always-present extra reduced the relaunched debug app to 0% idle CPU.
- A cold-open navigation test started with only `NSStatusBarWindow`; delivering
  `quorra://open/imds/default` created a visible `SwiftUI.AppKitWindow` titled
  `Quorra`. The temporary menu-bar-only preference was restored afterward.
- Signed sandboxed Debug app installed `/Users/aj/.local/bin/quorra`; the link
  ran the embedded CLI (`0.4.0`) and uninstall removed it. The test left no link.
- CLI smoke tests passed for `version` and `profiles list` table/JSON output.
- Xcode 27 cold CLI build: 189 build units; no AWS service/runtime target was
  compiled. SwiftPM still resolved the top-level AWS package dependency.
- Xcode 27 focused IPC suite: 11 passed, 0 failed, covering framing, version
  rejection, permissions, active/stale socket behavior, and the fallback locator.
- Signed Debug app and nested `dev.ajbeck.quorra.cli` helper both carry
  `9GEBAJV9R4.quorra`; deep strict signature verification passed. The embedded
  helper runs `version` and `profiles list` without the app sandbox.
- A fresh Xcode 27 beta Debug build passed after the internal SwiftPM product
  became `quorra-cli`. Both the embedded executable and
  `swift run quorra-cli --help` still render `USAGE: quorra <subcommand>`.
- The Release verifier's universal-binary check now uses `lipo`'s correct
  operand order and passes against the unsigned universal archive (`arm64` and
  `x86_64`). Entitlement extraction uses the current stdout form, and nested
  signature integrity remains covered by the enclosing app's Apple-recommended
  `codesign --verify --deep --strict` check.
- Live Terminal-equivalent commands passed for `imds list`, `imds status`,
  `imds stop`, and a no-op `imds switch-profile`. `imds start` reached the app
  and correctly returned the current expired-session error; a successful start
  remains to verify after authentication.
- Explicit lifecycle verification passed against the signed Debug products:
  a stopped app made `imds status` return the `quorra start` instruction,
  `quorra start` launched exactly one IPC-ready process, and `quorra stop`
  terminated it through the normal app lifecycle and removed the socket.
- The embedded CLI also passed a complete signed smoke sequence: stopped app,
  explicit start, standalone `version` and `profiles list`, IPC `imds list`,
  and explicit stop. A newly built app required one Launch Services registration
  in this development environment; subsequent direct launches succeeded.
- `LSMultipleInstancesProhibited` was verified in the built app. Attempting to
  open a second signed copy returned the first process's PID, and `ps` confirmed
  exactly one Quorra process. The release workflow now enforces the plist key.
- The signed Xcode 27 Debug app registered `SMAppService.mainApp` successfully;
  Settings reported launch at login enabled with no approval or error state,
  and the enabled status persisted across an app restart.
- A fresh unsigned Release archive embeds the current `0.4.0` helper at the
  stable path with both `arm64` and `x86_64` slices, the CLI bundle identifier,
  and `LSBackgroundOnly`. Local Developer ID archive export remains unavailable
  without the CI distribution provisioning profile; signed Debug verification
  and CI export gates cover signatures and App Group entitlements. A subsequent
  release-shaped archive injected `MARKETING_VERSION=0.4.0`: the app plist and
  embedded CLI both report `0.4.0`, both executables are universal (`arm64` and
  `x86_64`), and the helper retains `dev.ajbeck.quorra.cli`,
  `LSBackgroundOnly`, and public `quorra` usage.
- `actionlint` currently flags the inherited release-token configuration:
  `actions/create-github-app-token@v3` requires `app-id`. The workflow now uses
  the repository's existing `RELEASE_PLEASE_APP_ID`, and `actionlint` passes.
- The release archive now uses Xcode 27 and the unambiguous `QuorraApp` scheme.
  The nested helper owns its Developer ID Release identity, while package targets
  receive no workspace-wide signing override. CI rejects an exported helper
  whose signing authority is not Developer ID Application.
- App-owned profile sign-in is implemented with start/status/cancel IPC
  operations. Six focused Xcode 27 tests pass, covering state transitions,
  failure prose, cancellation forwarding, invalid profiles, command parsing,
  and a credential-free wire payload. A live missing-profile request reached
  the running app and returned a concise runtime error without usage noise.
- Authenticated end-to-end CLI verification passed. The Default endpoint
  switched to `ac:mgmt:admin`, started on `127.0.0.1:7114`, and restored itself
  after an Xcode-controlled background app restart. A denied live switch kept
  serving the previous known-good profile atomically. The endpoint was then
  stopped and restored to its original `ac:cp:org_admin` configuration. AWS
  currently denies that profile's `OrganizationAdmin` role-credential request
  with `ForbiddenException: No access`; the same authenticated SSO session
  successfully serves the permitted `ac:mgmt:admin` role.
