# Direct Distribution IMDSv2 System Extension Roadmap

This document is the durable design graph and decision log for making Quorra
available at the standard EC2 Instance Metadata Service address through a
Developer ID distributed system extension. This is the working implementation
checklist and decision log; update it whenever scope, status, or a decision
changes.

## Distribution Decision

Quorra is distributed directly as a notarized Developer ID application. The
IMDS transparent proxy is packaged as a Network Extension system extension in
`quorra.app/Contents/Library/SystemExtensions`, not as a Mac App Store
`.appex`. The containing app remains sandboxed.

The release artifact, Sparkle update feed, embedded CLI, and system extension
are one product. Mac App Store and TestFlight distribution are out of scope for
this implementation because Apple uses a different Network Extension packaging
form for those channels.

## Goal

Allow AWS SDKs and command-line tools running directly on macOS to use Quorra
without setting `AWS_EC2_METADATA_SERVICE_ENDPOINT`. A client that opens
`http://169.254.169.254` must complete the normal IMDSv2 token and metadata
flows.

The goal is behavioral compatibility. Quorra does not need to assign
`169.254.169.254` to a host interface or own a conventional port 80 listener.
Virtual machines and containers have independent network stacks and remain out
of scope until their routing requirements are designed separately.

## Design Graph

```text
Canonical EC2-compatible endpoint
├── client-visible contract
│   ├── destination 169.254.169.254:80
│   ├── HTTP over TCP
│   └── IMDSv2 required by default
├── system-managed transparent proxy
│   ├── sandboxed Network Extension system extension
│   ├── one outbound TCP rule for 169.254.169.254/32:80
│   ├── all unmatched flows bypass Quorra
│   ├── intercepted flow relayed as an opaque byte stream
│   ├── activation and replacement managed by SystemExtensions
│   └── proxy configuration managed by NetworkExtension
└── sandboxed Quorra backend
    ├── 127.0.0.1:7114 listener
    ├── token and metadata routing
    ├── credential refresh
    └── request logging and profile switching
```

## Delivery Status

| Stage | Status | Exit condition |
| --- | --- | --- |
| Direct-distribution architecture | Complete | Developer ID system-extension boundary and release gates are documented |
| Runtime configuration | Complete | Canonical and backend endpoints are distinct and options reach the server |
| App-extension prototype | Complete | The `.appex` prototype receives and relays only canonical IMDS TCP flows |
| System-extension packaging | Complete | A development build produces and embeds a `.systemextension` in the required bundle location |
| Activation lifecycle | In progress | Install, approval, replacement, cancellation, and failure states are handled |
| Proxy lifecycle and UX | In progress | Activation and network-configuration states are visible and recoverable |
| Developer ID signing | In progress | Host and extension use explicit Developer ID profiles and pass signature checks |
| Notarized release artifact | Not started | CI exports, notarizes, staples, and verifies the complete application |
| End-to-end release verification | Not started | Installed release candidate passes the clean-machine verification matrix |

## Active Decisions

### D013 — Behavioral compatibility over interface ownership

**Decision:** Use a sandboxed `NETransparentProxyProvider`, packaged as a
Developer ID Network Extension system extension, to intercept outbound TCP
flows whose destination is exactly `169.254.169.254:80`. Relay each selected
flow to Quorra's loopback backend. Do not assign the address to `lo0`, bind a
privileged port, or install a privileged launch daemon.

**Reasoning:** The product requirement is that unmodified AWS clients can reach
the standard IMDSv2 endpoint. Apple provides transparent proxy network rules
that select flows by destination address and port. Apple documents a system
extension as the Developer ID deployment form and an app extension as the Mac
App Store deployment form. The system extension preserves App Sandbox and
avoids root privilege while satisfying the observable client contract.

This decision supersedes D001, D003 through D006, and D008 through D012 below.
Those entries remain in the history section to record why the earlier design
was abandoned.

### D014 — Public and backend endpoints remain distinct

**Decision:** The client-visible destination remains `169.254.169.254:80`; the
private backend remains `127.0.0.1:7114`.

**Reasoning:** The extension selects the canonical destination without asking
clients for an override. The existing loopback backend retains all HTTP,
IMDSv2, profile, credential, and logging behavior.

### D015 — Narrow transparent-proxy rule

**Decision:** Install one outbound TCP rule for the single host prefix
`169.254.169.254/32` and port `80`. Return control to the operating system for
any flow that does not match the endpoint contract.

**Reasoning:** A narrowly scoped rule minimizes impact on the host networking
stack and makes Quorra independent of unrelated web, link-local, VPN, and local
network traffic.

### D016 — Opaque credential transport

**Decision:** The extension may transiently copy opaque TCP buffers between the
intercepted flow and loopback backend, but it never interprets, persists, or
logs their contents. Release buffers when each flow closes.

**Reasoning:** IMDS tokens and credential responses necessarily cross the
relay's memory. Keeping protocol behavior in the existing backend produces a
smaller extension and preserves one implementation of IMDSv2 security rules.

### D017 — System-owned proxy configuration

**Decision:** Configure and enable the transparent proxy through
`NETransparentProxyManager`. Clearly explain the narrowly scoped endpoint
interception before macOS presents its network-configuration approval. Treat
approval denial and a disabled extension as normal recoverable states.

**Reasoning:** Network Extension is Apple's supported system networking
boundary. Quorra must not imitate approval, install separate privileged code,
or assume the configuration remains enabled.

### D018 — Preserve approved configuration

**Decision:** Reuse an existing enabled transparent-proxy configuration when
its provider identity and settings already match Quorra's desired
configuration. Save preferences only when the configuration must change.

**Reasoning:** macOS persists the user's network-configuration approval. An
ordinary endpoint stop/start or app relaunch must not rewrite an unchanged
configuration or cause another approval prompt. Approval may be required again
after the configuration is removed, the app's signing identity changes, or the
system network settings are reset.

### D019 — Return the accepted token lifetime

**Decision:** Include `X-Aws-Ec2-Metadata-Token-Ttl-Seconds` on a successful
IMDSv2 token response, using the same accepted lifetime encoded in the token.

**Reasoning:** The AWS SDK for Go v2 uses this response header to cache and add
the token to later metadata requests. Returning only the token body works with
manual clients and the AWS CLI but does not satisfy the complete IMDSv2 client
contract.

### D020 — Direct Developer ID distribution

**Decision:** Ship a notarized Developer ID application and continue using
Sparkle for updates. Do not produce a Mac App Store or TestFlight artifact in
this implementation.

**Reasoning:** Apple's documented deployment form for a Network Extension
outside the Mac App Store is a system extension. Maintaining both `.appex` and
`.systemextension` artifacts would create two activation paths, entitlement
sets, signing configurations, and test matrices before the direct channel is
proven.

### D021 — System extension activation precedes proxy configuration

**Decision:** The app activates the embedded extension with
`OSSystemExtensionManager` before it creates or starts the
`NETransparentProxyManager` configuration. Activation state and network
configuration state are modeled separately.

**Reasoning:** A system extension can require installation, user approval,
replacement approval, or restart independently of the transparent proxy
configuration. Combining those states would produce misleading readiness and
error reporting.

### D022 — One active desktop user per Mac for the first release

**Decision:** Support one active Quorra desktop session per Mac. Fail closed
when the loopback backend is unavailable, surface backend port conflicts, and
document the local-process trust boundary. Fast user switching and a second
simultaneous Quorra session are unsupported until explicitly designed.

**Reasoning:** The installed system extension and network configuration are
system-scoped while Quorra's backend, credentials, and Keychain state belong to
a logged-in user. An explicit restriction is safer than allowing a global
proxy to route silently to an ambiguous user session.

### D023 — Normal Xcode export first

**Decision:** Use Xcode 27's normal Developer ID archive/export workflow with
separate explicit provisioning profiles for the host and system extension.
Only adopt manual inside-out signing if a reproducible Xcode export defect
requires it.

**Reasoning:** Normal export keeps nested-code signing, entitlements, and
notarization aligned with Apple's supported toolchain and minimizes custom
release machinery.

### D024 — Configuration-specific Network Extension entitlement

**Decision:** Expand the Network Extension entitlement from a build setting.
Development builds signed with Apple Development use `app-proxy-provider`, as
generated by Apple's Network Extension system-extension template. Release
builds signed with Developer ID use `app-proxy-provider-systemextension`.

**Reasoning:** Apple assigns the `-systemextension` entitlement values to
Developer ID profiles specifically. Using that value in Debug makes the normal
Mac development provisioning profiles invalid even though the product is
correctly packaged as a `.systemextension`.

### D025 — Disable configuration; let app deletion uninstall

**Decision:** Turning off the default EC2 metadata URL removes Quorra's
transparent-proxy network configuration but does not deactivate the approved
system extension. Deleting Quorra is the supported full-uninstall path; do not
add a routine settings control that submits a system-extension deactivation
request.

**Reasoning:** Apple automatically uninstalls a system extension when the user
deletes its containing app. Keeping the inert extension installed makes a
later re-enable inexpensive, while an explicit deactivation request can itself
require a restart and adds destructive state that is unnecessary during normal
endpoint operation.

### D026 — Repair stale network configuration in place

**Decision:** Treat system-extension installation and transparent-proxy
configuration as separate states. When the extension is installed but the
default endpoint cannot connect, offer an explicit repair action that removes
Quorra's saved `NETransparentProxyManager` configuration and creates a fresh
one for the currently installed provider.

**Reasoning:** macOS can preserve a network configuration whose code-signing
requirement names an older development build after the extension has been
replaced by a Developer ID build. The new provider is then correctly installed
but cannot satisfy the stale configuration's designated requirement. Recreating
only the routing configuration repairs that mismatch without deactivating the
approved system extension.

### D027 — Dock presence follows interactive windows

**Decision:** Quorra uses the regular application activation policy whenever a
main or Settings window is open. If the user enables background-only behavior,
Quorra returns to the accessory policy only after the last interactive window
closes; losing focus never closes or hides a window.

**Reasoning:** Opening an application establishes the macOS expectation that it
has a Dock icon and persistent windows. The accessory policy remains useful for
a quiet menu-bar process, but it must not make an explicitly opened Quorra
window disappear when the user switches applications.

### D028 — Settings are organized by user task

**Decision:** Use stable macOS Settings toolbar panes for General, Background,
IMDS, and About. Keep each pane as a native grouped form, and use one compact
extension-to-routing status path in the IMDS pane to communicate the dependency
between those otherwise separate states.

**Reasoning:** Apple's Human Interface Guidelines recommend stable,
noncustomizable panes for macOS app settings, grouping related controls, and
using switches for significant on/off behavior. Task-based panes make the
previous long list easier to scan while keeping system integration and its
recovery action together.

## Superseded Designs

### Mac App Store app-extension packaging

The signed `.appex` prototype proved that the transparent-proxy rule, relay,
loopback backend, AWS CLI, and AWS SDK behavior work. It is superseded only as a
distribution form: Apple documents `.appex` for Mac App Store distribution and
`.systemextension` for Developer ID distribution. The provider and relay logic
remain the basis of the system extension.

### Privileged helper

The first implementation assigned `169.254.169.254/32` to `lo0`, bound port 80
in a root launch daemon, and relayed to the app. It established the following
useful invariants:

- The canonical and loopback backend endpoints are separate runtime concepts.
- Credentials and IMDS tokens are never persisted or logged by a relay.
- Relays are bounded and fail closed when their backend is unavailable.
- Exact code-signing requirements authenticate cross-process control planes.
- Ambiguous system-owned state must never be removed destructively.

It was superseded because Apple requires Mac App Store apps to remain
sandboxed, explicitly lists network-setting configuration as incompatible with
App Sandbox, and does not support a sandboxed app registering an unsandboxed
job. It also required root for both the interface alias and port 80. The prior
implementation remains available in branch history through commit `916ce44`
while the transparent-proxy design is validated.

## Implementation Sequence

- [x] Prove the exact transparent-proxy rule and bounded relay in a signed app
  extension.
- [x] Verify IMDSv2 with `curl`, AWS CLI, and an AWS SDK without an endpoint
  environment override.
- [x] Convert the provider target product from `.appex` to `.systemextension`.
- [x] Embed it at `Contents/Library/SystemExtensions` and add the system
  extension entry point that calls `NEProvider.startSystemExtensionMode()`.
- [x] Change the provider entitlement to
  `app-proxy-provider-systemextension`; add
  `com.apple.developer.system-extension.install` to the host.
- [x] Add an activation controller using `OSSystemExtensionManager` and model
  activation, approval, replacement, cancellation, restart, and failure.
- [x] Gate `NETransparentProxyManager` installation/start on successful system
  extension activation without rewriting an unchanged approved configuration.
- [ ] Add UI and diagnostics for `/Applications` installation, system-extension
  approval, network-configuration approval, failure, and recovery.
- [x] Enforce and document the first-release single-active-user policy and
  backend port-conflict behavior.
- [ ] Register the host and extension identifiers/capabilities in the Apple
  Developer portal and create separate Developer ID provisioning profiles.
- [ ] Update CI export options and signing imports for both profiles; verify the
  embedded path, identifiers, Team ID, entitlements, hardened runtime, and
  nested signatures.
- [ ] Export, notarize, staple, and Gatekeeper-assess a prerelease artifact.
- [ ] Verify clean install, approval, update, restart, uninstall, VPN, sleep,
  wake, multi-user failure behavior, and AWS CLI/SDK compatibility.
- [ ] Update installation, troubleshooting, privacy, security, and release
  documentation before shipping.

## Security and Failure Invariants

- The proxy rule matches only outbound TCP to `169.254.169.254:80`.
- Unmatched traffic is never claimed, inspected, copied, or delayed by Quorra.
- The extension never interprets, persists, or logs credentials, tokens, or
  HTTP payloads.
- The backend listener binds exactly `127.0.0.1:7114`.
- Concurrent flows and per-flow buffers have explicit limits.
- Backend unavailability closes only the affected flow and never changes host
  routes or interface configuration.
- Secrets remain redacted from logs in both processes.
- The app and system extension remain sandboxed and require no root process.
- The system extension is activated only from the matching Team ID host app.
- A missing user backend or ambiguous ownership fails closed.

## Feasibility Gate

Before completing release integration, verify on a clean macOS 26 system that:

- The provider receives a connection from `curl` to
  `169.254.169.254:80` even though the address is not assigned locally.
- A destination-address-and-port rule does not capture unrelated link-local or
  HTTP traffic.
- The provider can open and exchange data with `127.0.0.1:7114` under its
  production sandbox entitlements.
- System-extension activation and transparent-proxy configuration have
  understandable, distinct consent and Settings behavior.
- AWS CLI and at least one AWS SDK complete PUT-token and credential requests
  without an endpoint environment variable.
- An app installed outside `/Applications` receives an actionable explanation.
- A Sparkle update replaces the approved extension without orphaning the old
  version or leaving the proxy in an ambiguous state.

If any gate fails, first distinguish packaging/signing, activation, proxy
configuration, and relay failures. Do not restore the root design merely to
work around signing, provisioning, or test setup problems.

## Verification Matrix

- Fresh install with network configuration approval granted, deferred, and
  denied.
- Enable, disable, repeated enable, app restart, extension restart, and reboot.
- App crash while the extension is active and extension failure while the app
  is active.
- VPN enabled, Wi-Fi changes, sleep and wake, and fast user switching.
- IMDSv2 token creation, invalid and expired tokens, metadata reads, credential
  refresh, and live profile switching.
- Development-signed debug build and Developer ID release archive.
- Notarization, stapling, Gatekeeper assessment, first install, and update over
  an older system extension.
- App outside `/Applications`, approval deferred/denied, extension replacement
  denied, restart required, and stale configuration recovery.
- Logout, login, fast user switching, second-user launch, backend absence, and
  port ownership conflicts; unsupported combinations must fail visibly.

## Verification Record

### 2026-09-12 — Signed debug feasibility and client compatibility

- Built and ran the sandboxed app with its embedded, signed Network Extension.
- Granted the macOS network-configuration approval once; a rebuild and relaunch
  reused the approved configuration without another prompt.
- Completed IMDSv2 token, role-name, and credential requests with `curl` at
  `http://169.254.169.254` and confirmed that an IMDSv1 request returns `401`.
- Resolved credentials and region through the AWS CLI's default provider chain
  with no endpoint override; the reported sources were `iam-role` and `imds`.
- Resolved credentials through the AWS SDK for Go v2 default provider chain
  with no endpoint override; the provider was `EC2RoleProvider`.
- Passed all 420 QuorraCore tests, including all 14 focused IMDS router tests,
  after adding the token lifetime response header. The full Xcode test plan
  passed earlier in the implementation sequence and remains a release gate.

Developer ID system-extension conversion, release archive, notarization,
denial recovery, reboot, sleep/wake, VPN interaction, Sparkle replacement, and
extension-failure scenarios remain open.

## Authoritative References

- [TN3134: Network Extension provider deployment](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)
- [Installing system extensions and drivers](https://developer.apple.com/documentation/systemextensions/installing-system-extensions-and-drivers)
- [`NEProvider.startSystemExtensionMode()`](https://developer.apple.com/documentation/networkextension/neprovider/startsystemextensionmode())
- [Network Extension entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension)
- [Human Interface Guidelines: Settings](https://developer.apple.com/design/human-interface-guidelines/settings)
- [Human Interface Guidelines: Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
- [Human Interface Guidelines: Toggles](https://developer.apple.com/design/human-interface-guidelines/toggles)
