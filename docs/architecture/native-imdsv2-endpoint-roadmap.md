# Native IMDSv2 Endpoint Roadmap

This document is the durable design graph and decision log for exposing
Quorra's reserved metadata endpoint at the standard EC2 Instance Metadata
Service address. Update it whenever scope, status, or a decision changes.

## Goal

Allow host-native AWS tools to use Quorra without an endpoint override by
serving IMDSv2 at `http://169.254.169.254` while keeping AWS credentials and
metadata protocol handling out of privileged code.

The first delivery targets processes running directly on macOS. Virtual
machines and containers have independent network stacks and are out of scope
until their routing requirements are designed and tested separately.

## Design Graph

```text
Canonical EC2-compatible endpoint
├── public contract
│   ├── IPv4 address 169.254.169.254/32
│   ├── HTTP port 80
│   └── IMDSv2 required by default
├── unprivileged Quorra backend
│   ├── 127.0.0.1:7114 listener
│   ├── token and metadata routing
│   ├── credential refresh
│   └── request logging and profile switching
└── privileged network frontend
    ├── SMAppService launch daemon registration
    ├── authenticated XPC control plane
    ├── idempotent lo0 alias ownership
    ├── 169.254.169.254:80 listener
    ├── app-group Mach service: 9GEBAJV9R4.quorra.imds-helper
    ├── byte-stream relay to 127.0.0.1:7114
    └── cleanup and conflict recovery
        ├── address already configured
        ├── port already occupied
        ├── backend unavailable
        ├── app or daemon restart
        └── disable, update, and removal
```

## Delivery Status

| Stage | Status | Exit condition |
| --- | --- | --- |
| Architecture and invariants | Complete | Security boundary and ownership rules are documented |
| Runtime configuration | Complete | Public and backend endpoints are distinct and options reach the server |
| Privileged helper | In progress | Signed launch daemon registers and exposes an authenticated control plane |
| Interface and relay | Complete | Owned `/32` alias and port 80 relay work idempotently |
| App lifecycle and UX | Not started | Approval, readiness, conflicts, and disablement are visible and recoverable |
| Distribution | Not started | Universal signed helper passes archive and notarization checks |
| End-to-end verification | Not started | Standard AWS clients complete IMDSv2 flows without endpoint overrides |

## Decisions

### D001 — Privilege boundary

**Decision:** A minimal root launch daemon owns only the network-interface alias,
the public TCP listener, and a byte-stream relay. The sandboxed Quorra app keeps
the IMDS protocol, credentials, profile selection, refresh, and logging.

**Reasoning:** macOS permits only the superuser to modify interface
configuration. Keeping credential-bearing behavior in the existing user
process minimizes privileged code and avoids copying AWS credentials across a
privilege boundary.

### D002 — Public and backend addresses

**Decision:** The public endpoint is `169.254.169.254:80`; the private backend
remains `127.0.0.1:7114`. These are separate runtime concepts even though the UI
presents one reserved endpoint.

**Reasoning:** AWS clients use the standard HTTP endpoint without a port
override. Quorra already serves the protocol on port 7114, and a loopback
backend lets the root component remain protocol-agnostic.

### D003 — Interface scope

**Decision:** Add only `169.254.169.254/32` as an alias on `lo0`, never the whole
`169.254.0.0/16` link-local range and never a wildcard listener.

**Reasoning:** A host route makes the address local without claiming unrelated
link-local traffic or exposing the listener on physical interfaces.

### D004 — User authorization

**Decision:** Register the helper with `SMAppService.daemon(plistName:)` after an
explicit user action. Reflect `SMAppService.Status` in the UI and direct the
user to Login Items settings when approval is required.

**Reasoning:** A launch daemon is the supported macOS mechanism for this
system-level work and requires user authorization. Quorra already uses
`SMAppService` and has established status and settings-navigation patterns.

### D005 — Control-plane authentication

**Decision:** Limit helper commands to status, enable, and disable. Require the
calling process to have Quorra's signing identifier and Team ID before accepting
an XPC request. The app likewise requires the helper's exact signing identifier
and Team ID before sending a request. Keep the shared Objective-C protocol and
signing constants in `QuorraIPC`; privileged behavior remains private to the
helper targets.

**Reasoning:** A system-wide Mach service must not let arbitrary local processes
change network configuration. Code-signing requirements are stronger than PID,
UID, or filesystem-path checks. Foundation's connection-level signing
requirements fail closed before an exported method is dispatched and avoid a
custom audit-token validation path.

### D006 — Address ownership

**Decision:** If the metadata address is already configured and Quorra cannot
establish ownership, report a conflict and do not alter it. Remove the alias
only when the helper can prove it created it. Record ownership in a root-owned,
mode `0600` marker under `/var/run`; reclaim `marker + alias on lo0` after a
daemon crash, and treat `alias without marker` as foreign.

**Reasoning:** Interface aliases have no native ownership metadata. Refusing to
take over or remove ambiguous state prevents Quorra from disrupting another
tool, VPN, or administrator configuration. `/var/run` survives a daemon restart
but is cleared at reboot, matching the nonpersistent interface alias lifecycle.

### D007 — Local Network privacy

**Decision:** Do not add `NSLocalNetworkUsageDescription` solely for this
feature. Retain the app's existing incoming-network sandbox entitlement.

**Reasoning:** Apple documents that accepting incoming TCP connections is not a
Local Network privacy operation and that launch daemons are automatically
allowed. A usage description should be added only if later work introduces an
operation that actually requires that permission.

### D008 — Backend outages

**Decision:** Keep the owned alias and public listener active when the
unprivileged backend is temporarily unavailable. Fail the affected TCP
connection without buffering its request, then attempt a fresh loopback
connection for the next client.

**Reasoning:** The app and launch daemon have independent lifecycles. Keeping
the stable public endpoint avoids privileged interface churn and lets normal
service resume as soon as Quorra restarts, while a hard concurrent-connection
limit bounds resource use in the daemon.

### D009 — Transactional activation

**Decision:** Enable by probing the loopback backend, acquiring the owned
interface alias, and then starting the public listener. If listener startup
fails, remove the owned alias. Disable in reverse dependency order by stopping
the listener before removing the alias.

**Reasoning:** This ordering prevents Quorra from advertising a ready endpoint
without a backend and prevents new clients from arriving while its address is
being removed. Reporting both startup and rollback failures preserves the
information needed for safe recovery.

### D010 — Daemon bundle layout

**Decision:** Embed the signed `QuorraIMDSHelper.app` under the main app's
`Contents/Helpers` directory and point the launch-daemon plist's
`BundleProgram` at its inner executable. Embed the plist under
`Contents/Library/LaunchDaemons`.

**Reasoning:** `SMAppService` requires a bundle-relative helper executable and
a launch-daemon plist in that exact Library directory. Retaining the helper as
a nested, GUI-less app keeps its private framework, hardened-runtime signature,
and identifier in one independently verifiable code-signing unit.

### D011 — Opaque credential transport

**Decision:** The privileged helper may transiently copy opaque TCP buffers
between the public listener and loopback backend, but it never interprets,
persists, or logs their contents. Release per-connection buffers when each
connection closes.

**Reasoning:** IMDS credential responses and tokens necessarily cross the
relay's memory. Treating them strictly as bounded byte streams keeps HTTP,
token, credential, and AWS behavior out of privileged code while avoiding the
additional lifecycle and POSIX-server complexity of passing a bound socket to
the sandboxed app.

### D012 — Sandboxed XPC namespace

**Decision:** Publish the daemon's Mach service as
`9GEBAJV9R4.quorra.imds-helper`, a child of Quorra's existing App Group ID. The
app connects with `NSXPCConnection`'s privileged option. Do not use a temporary
Mach-lookup exception or disable App Sandbox.

**Reasoning:** Apple documents App Groups as the standard namespace for a
sandboxed client to reach a global launch-daemon XPC endpoint. Quorra's App
Group entitlement is already provisioning-profile-authorized; the unsandboxed
daemon does not need to claim that entitlement merely to publish the child
service name.

## Implementation Sequence

1. Extract endpoint constants and a runtime configuration that distinguishes
   the public endpoint from the loopback backend.
2. Add regression tests for reserved-definition repair and runtime option
   propagation, including IMDSv2-only behavior.
3. Add the helper executable target, embedded launch-daemon property list,
   signing configuration, and `SMAppService` controller.
4. Define the narrow XPC request and response contract and enforce peer
   code-signing requirements in both directions.
5. Implement interface inspection, conflict detection, idempotent alias
   creation, and ownership-aware cleanup behind test doubles.
6. Implement the public listener and bounded bidirectional relay to the
   loopback backend.
7. Integrate helper readiness and failure states with default-endpoint startup,
   restoration, notifications, Settings, and CLI status.
8. Extend archive, signature, architecture, notarization, and clean-machine
   release verification for the nested daemon.
9. Verify token acquisition and credential retrieval with `curl`, AWS CLI, and
   an AWS SDK without `AWS_EC2_METADATA_SERVICE_ENDPOINT`.

## Security and Failure Invariants

- The privileged helper never interprets, persists, or logs AWS credentials or
  IMDS tokens; it handles them only as bounded, per-connection TCP buffers.
- The public listener binds exactly `169.254.169.254:80`.
- The backend listener binds exactly `127.0.0.1:7114`.
- Interface and port conflicts fail closed and identify the conflicting
  resource without attempting destructive recovery.
- Enabling is not reported successful until the alias, public listener, and
  backend are all ready.
- Disabling stops new public connections before removing an alias owned by the
  helper.
- Secrets remain redacted from logs in both processes.

## Verification Matrix

- Fresh install with helper approval granted, deferred, and denied.
- Enable, disable, repeated enable, app restart, daemon restart, and reboot.
- App crash while the daemon is active and daemon crash while the app is active.
- Existing address on `lo0`, address on another interface, and port 80 already
  occupied.
- VPN enabled, Wi-Fi changes, sleep and wake, and fast user switching.
- IMDSv2 token creation, invalid and expired tokens, metadata reads, credential
  refresh, and live profile switching.
- Debug, Developer ID archive, Sparkle update, notarized DMG, and app removal.
