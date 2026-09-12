# Native IMDSv2 Endpoint Roadmap

This document is the durable design graph and decision log for making Quorra
available at the standard EC2 Instance Metadata Service address. Update it
whenever scope, status, or a decision changes.

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
│   ├── sandboxed Network Extension app extension
│   ├── one outbound TCP rule for 169.254.169.254/32:80
│   ├── all unmatched flows bypass Quorra
│   ├── intercepted flow relayed as an opaque byte stream
│   └── lifecycle and approval managed by NetworkExtension
└── sandboxed Quorra backend
    ├── 127.0.0.1:7114 listener
    ├── token and metadata routing
    ├── credential refresh
    └── request logging and profile switching
```

## Delivery Status

| Stage | Status | Exit condition |
| --- | --- | --- |
| Architecture and invariants | Complete | Behavioral goal and Network Extension boundary are documented |
| Runtime configuration | Complete | Canonical and backend endpoints are distinct and options reach the server |
| Transparent-proxy feasibility | In progress | A signed extension receives only canonical IMDS TCP flows |
| Flow relay | Not started | Bidirectional relay reaches the loopback backend with bounded resources |
| App lifecycle and UX | Not started | Approval, readiness, failure, and disablement are visible and recoverable |
| Distribution | Not started | Sandboxed App Store archive contains valid extension entitlements and signatures |
| End-to-end verification | Not started | AWS CLI and an AWS SDK complete IMDSv2 without endpoint overrides |

## Active Decisions

### D013 — Behavioral compatibility over interface ownership

**Decision:** Use a sandboxed `NETransparentProxyProvider` to intercept outbound
TCP flows whose destination is exactly `169.254.169.254:80`. Relay each selected
flow to Quorra's loopback backend. Do not assign the address to `lo0`, bind a
privileged port, or install a privileged launch daemon.

**Reasoning:** The product requirement is that unmodified AWS clients can reach
the standard IMDSv2 endpoint. Apple provides transparent proxy network rules
that select flows by destination address and port, and documents an app
extension as the Mac App Store deployment form. This preserves App Sandbox and
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

### D017 — System-owned approval and lifecycle

**Decision:** Configure and enable the transparent proxy through
`NETransparentProxyManager`. Clearly explain the narrowly scoped endpoint
interception before macOS presents its network-configuration approval. Treat
approval denial and a disabled extension as normal recoverable states.

**Reasoning:** Network Extension is Apple's supported system networking
boundary for sandboxed App Store software. Quorra must not imitate approval,
install separate privileged code, or assume the extension remains enabled.

## Superseded Privileged-Helper Design

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

1. Remove the launch-daemon target, alias adapter, privileged listener, XPC
   contract, and `SMAppService` UI from the product.
2. Add a macOS Network Extension app-extension target embedded in Quorra.
3. Add the Network Extension entitlement to the containing app and provider;
   retain App Sandbox and the existing App Group.
4. Implement and unit-test construction of the exact outbound TCP network rule.
5. Configure the provider with `NETransparentProxyNetworkSettings` and decline
   every unmatched flow.
6. Implement a bounded bidirectional relay from `NEAppProxyTCPFlow` to
   `127.0.0.1:7114` without inspecting or logging payloads.
7. Replace helper registration state with `NETransparentProxyManager`
   configuration and connection status.
8. Integrate approval, readiness, restoration, notifications, Settings, and
   CLI status with the default endpoint lifecycle.
9. Validate a sandboxed App Store archive, provisioning profile, extension
   embedding, and signatures.
10. Verify token acquisition and credential retrieval with `curl`, AWS CLI,
    and an AWS SDK without `AWS_EC2_METADATA_SERVICE_ENDPOINT`.

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
- The app and extension remain sandboxed and require no root process.

## Feasibility Gate

Before completing UI integration, verify on a clean macOS 26 system that:

- The provider receives a connection from `curl` to
  `169.254.169.254:80` even though the address is not assigned locally.
- A destination-address-and-port rule does not capture unrelated link-local or
  HTTP traffic.
- The provider can open and exchange data with `127.0.0.1:7114` under its
  production sandbox entitlements.
- Starting and stopping the configuration has understandable system consent
  and Settings behavior.
- AWS CLI and at least one AWS SDK complete PUT-token and credential requests
  without an endpoint environment variable.

If any gate fails because the framework does not deliver this destination to a
provider, revisit direct Developer ID distribution. Do not restore the root
design merely to work around signing, provisioning, or test setup problems.

## Verification Matrix

- Fresh install with network configuration approval granted, deferred, and
  denied.
- Enable, disable, repeated enable, app restart, extension restart, and reboot.
- App crash while the extension is active and extension failure while the app
  is active.
- VPN enabled, Wi-Fi changes, sleep and wake, and fast user switching.
- IMDSv2 token creation, invalid and expired tokens, metadata reads, credential
  refresh, and live profile switching.
- Debug, Mac App Distribution archive, TestFlight, and Mac App Store validation.
