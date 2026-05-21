# AWS SDK for Swift — IAM Identity Center Migration

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Quorra's hand-rolled AWS SSO OIDC + Portal transport with the official AWS SDK for Swift (`AWSSSOOIDC`, `AWSSSO`). The migration *itself* fixes the production bug where a single fixed-region `OIDCClient` is shared across all SSO sessions — sign-ins for any session whose region differs from the hardcoded `us-east-1` get rejected with `invalid_request: Invalid start url provided`. The SDK adapter is region-correct from the first commit because `SSOOIDCClient` is constructed per-region via a small factory seam.

**Architecture:**
- The lifecycle actor `IdentityCenterService` is preserved verbatim — timers, single-flight maps, the `AsyncStream<AuthEvent>`, session locks, and Keychain-backed token storage are Quorra-specific value and are not in the SDK.
- An `OIDCClientProviding` factory is injected into the actor. The factory builds a region-correct `SSOOIDCClient`-backed `OIDCRequesting` on demand, keyed by region. Senders of a sign-in action (`CredentialsModel` / views) supply the region; the provider supplies the routed client. This is the single seam that fixes the bug.
- `PortalRequesting` already takes `region:` per call, so no symmetric "provider" is needed for Portal — the SDK Portal adapter caches one `SSOClient` per region *internally* behind the existing protocol shape.
- The SDK is adopted *behind* the existing `OIDCRequesting` and `PortalRequesting` protocols. SDK types are translated to Quorra's domain types (`StoredOIDCClient`, `StoredSSOToken`, `DeviceVerification`, `MintedCredential`) at the adapter boundary so the actor never imports `AWSSSOOIDC`/`AWSSSO`.
- Tokens stay in the macOS Keychain. The SDK is used as a *transport*, not as a credential provider; we do not adopt the SDK's `~/.aws/sso/cache/*.json` flow.

**Tech Stack:** Swift 6.2 / Xcode 26, SwiftPM (QuorraCore package at `Packages/QuorraCore/`), `aws-sdk-swift` 1.7.1 (`AWSSSOOIDC`, `AWSSSO`), Swift Testing (`@Test`) for unit tests, macOS 26 (Tahoe) minimum.

**Ordering rationale:** Phase 1 introduces the SDK-backed OIDC adapter and provider seam together — it ships the bug fix and the SDK adoption in one coherent unit, then deletes the hand-rolled OIDC code in the same phase. Phase 2 does the same for Portal (including the sign-out `logout` call that currently uses a separate `PortalLogout` URLSession path). Phase 3 cleans up obsolete error cases, drops the now-unused `urlSession` parameter, and updates docs.

**Commit policy:** Follow CLAUDE.md — conventional commits, types `chore/feat/patch/docs/fix`. Slice commits at logical milestones the developer (or executing agent) actually reached, not at every task boundary. Each phase has *at least one* commit at its end and may have one or two intermediate commits if a natural unit emerges (e.g. "introduce adapter" then "delete hand-rolled transport"). Don't commit micro-steps. The plan calls out commit *checkpoints* (suggested boundaries with themes), not exact messages — write the message from what you actually changed.

---

## File Map

### New files (created across phases)

```
Packages/QuorraCore/Sources/IAMIdentityCenter/
├── OIDCClientProviding.swift               (Phase 1)
└── SDK/
    ├── SDKOIDCClient.swift                 (Phase 1)
    ├── SDKOIDCClientProvider.swift         (Phase 1)
    ├── SDKPortalClient.swift               (Phase 2)
    └── SDKErrorMapping.swift               (Phase 1; extended in Phase 2)

Packages/QuorraCore/Tests/IAMIdentityCenterTests/
├── Stubs/StubOIDCClientProvider.swift      (Phase 1)
└── SDK/SDKErrorMappingTests.swift          (Phase 1; extended in Phase 2)
```

`SDKErrorMapping` is the containment boundary that keeps AWS SDK for Swift types out of the rest of `IAMIdentityCenter`. To make it honestly testable, the mapping is structured as a **pure function over a `(typeName: String, message: String?)` discriminator pair** — no SDK imports in the function signature. A small `extract(from:)` helper does the dirty work of pulling the discriminator out of an SDK exception. Tests import only `IAMIdentityCenter`, exercise the pure mapper directly with string inputs, and never need to construct an SDK exception. If a future SDK version changes its error-discrimination protocol, only `extract(from:)` and Task 1.2 verification notes change — the mapping table and its tests are unaffected.

### Files to delete

**Phase 1 (OIDC):**
```
Packages/QuorraCore/Sources/IAMIdentityCenter/OIDCClient.swift
Packages/QuorraCore/Sources/IAMIdentityCenter/OIDCClient+Refresh.swift
Packages/QuorraCore/Sources/IAMIdentityCenter/Wire/RegisterClient.swift
Packages/QuorraCore/Sources/IAMIdentityCenter/Wire/StartDeviceAuthorization.swift
Packages/QuorraCore/Sources/IAMIdentityCenter/Wire/CreateToken.swift
Packages/QuorraCore/Sources/IAMIdentityCenter/Wire/RefreshToken.swift
Packages/QuorraCore/Tests/IAMIdentityCenterTests/OIDCClientTests.swift
Packages/QuorraCore/Tests/IAMIdentityCenterTests/OIDCClientRefreshTests.swift
```

**Phase 2 (Portal):**
```
Packages/QuorraCore/Sources/IAMIdentityCenter/PortalClient.swift
Packages/QuorraCore/Sources/IAMIdentityCenter/PortalLogout.swift
Packages/QuorraCore/Sources/IAMIdentityCenter/Wire/GetRoleCredentials.swift
Packages/QuorraCore/Sources/IAMIdentityCenter/Wire/ListAccounts.swift
Packages/QuorraCore/Sources/IAMIdentityCenter/Wire/ListAccountRoles.swift
Packages/QuorraCore/Sources/IAMIdentityCenter/Wire/AWSServiceErrorResponse.swift
Packages/QuorraCore/Sources/IAMIdentityCenter/Wire/OAuthErrorResponse.swift
Packages/QuorraCore/Sources/IAMIdentityCenter/Wire/Wire.swift
Packages/QuorraCore/Sources/IAMIdentityCenter/HTTPErrorMapping.swift
Packages/QuorraCore/Tests/IAMIdentityCenterTests/PortalClientTests.swift
```

### Files to modify

```
.gitignore                                                              — un-ignore Package.resolved (pre-Phase-1)
Packages/QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService.swift
Packages/QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService+Refresh.swift
Packages/QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService+Polling.swift
Packages/QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService+SignOut.swift
Packages/QuorraCore/Sources/IAMIdentityCenter/PortalRequesting.swift   — add logout verb (Phase 2)
Packages/QuorraCore/Sources/IAMIdentityCenter/Errors.swift             — prune obsolete cases (Phase 3)
Packages/QuorraCore/Sources/IAMIdentityCenter/Errors+LocalizedError.swift  (Phase 3)
App/quorraApp.swift                                                    — wire SDK providers
Packages/QuorraCore/Tests/IAMIdentityCenterTests/Stubs/StubPortalRequesting.swift  — add logout stub
Packages/QuorraCore/Tests/IAMIdentityCenterTests/**/*Tests.swift       — update init sites
docs/IAMIdentityCenterPlan.html
CLAUDE.md
README.md                                                              — onboarding note for Smithy plugin trust
```

---

## Phase 0 — SDK Spike & Gate

**Status: COMPLETE** (commits `182e018`, `185c851`). See Phase 0 Notes at the bottom of this file for the gate decision and pinned versions.

### Phase 0 follow-up — un-ignore `Package.resolved`

Phase 0 Notes flagged this as a separate decision. Action it now, before Phase 1.

- [ ] **Step 1: Confirm `Package.resolved` is currently gitignored**

```bash
git check-ignore -v Quorra.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

Expected: a line showing which `.gitignore` rule matches.

- [ ] **Step 2: Edit `.gitignore` to un-ignore the workspace-pinned `Package.resolved`**

Add a negation line. Example:
```
!Quorra.xcworkspace/xcshareddata/swiftpm/Package.resolved
```
(Place it after whichever rule was matching.)

- [ ] **Step 3: Commit**

Single self-contained change — commit the `.gitignore` edit and the lockfile together. `chore(deps):` type.

---

## Phase 1 — SDK-Backed OIDC (ships the bug fix)

> **Goal:** introduce the SDK-backed OIDC adapter + provider seam, route the production app through it, and delete the hand-rolled OIDC transport. The provider seam keys clients by *region*, which fixes the production bug. The hand-rolled `OIDCClient` is never run with the seam in place — it's removed in the same phase.

### Task 1.1: Add `OIDCClientProviding` protocol

**Files:**
- Create: `Packages/QuorraCore/Sources/IAMIdentityCenter/OIDCClientProviding.swift`

- [ ] **Step 1: Write the protocol**

```swift
// OIDCClientProviding.swift — factory for region-correct OIDC clients.
//
// The actor never holds a client directly; it asks the provider for one keyed
// by region every time it makes a call. This decouples client construction
// (region-bound by SDK config) from the actor's lifecycle (region-agnostic).
import Foundation

public protocol OIDCClientProviding: Sendable {
    /// Returns an `OIDCRequesting` configured for the given AWS region.
    ///
    /// Implementations may cache per-region instances; callers must not assume identity.
    func client(forRegion region: String) async throws -> any OIDCRequesting
}
```

- [ ] **Step 2: Build**

Run `mcp__xcode__BuildProject` (tabIdentifier: `windowtab1`). Expected: BUILD SUCCEEDED.

### Task 1.2: Pre-Phase-1 SDK type verification

> Before writing the adapter, confirm the SDK initializer + Input/Output type spellings against the resolved version (1.7.1). Phase 0 Task 0.2 was skipped, so this verification step lives here.

- [ ] **Step 1: Open the AWS SDK for Swift DocC**

Use the AWS Documentation MCP:
```
mcp__aws-documentation__search_documentation
  search_phrase: "AWS SDK for Swift SSOOIDCClient register client"
  limit: 5
```

Or pull DocC directly via `mcp__xcode__DocumentationSearch` for `SSOOIDCClient`, `RegisterClientInput`, `StartDeviceAuthorizationInput`, `CreateTokenInput`. Record in this file (Phase 1 Notes section at the bottom):
- Exact config initializer name (e.g. `SSOOIDCClient.SSOOIDCClientConfiguration(region:)` vs `SSOOIDCClient.Config(region:)`)
- Whether config init is `async throws` or `throws`
- Input parameter labels and required vs optional fields
- Output field optionality (`accessToken: String?` vs `String`)

- [ ] **Step 2: Same verification for `SSOClient` (used in Phase 2)**

`GetRoleCredentialsInput`, `GetRoleCredentialsOutput`, `LogoutInput`, `ListAccountsInput`, `ListAccountRolesInput`, and the nested `RoleCredentials` shape (note especially: `expiration` unit — milliseconds vs seconds since epoch).

- [ ] **Step 3: Verify the SDK error-discrimination protocol**

`SDKErrorMapping.extract(from:)` (Task 1.3) needs to pull a Smithy type name + message out of any thrown SDK exception. Search the SDK / `ClientRuntime` / `smithy-swift` DocC for the protocol that exposes this. Likely candidates:
- `ClientRuntime.ServiceError` — typically has `typeName: String` and `message: String?`
- `ClientRuntime.ModeledError` — newer SDK versions may use this
- `AWSClientRuntime.AWSServiceError` — for AWS-specific service errors

Record in Phase 1 Notes:
- Exact protocol name to cast `error as?`
- Exact property name for the type discriminator (`typeName`, `errorCode`, `errorType`, …)
- Exact property name for the message
- Whether the protocol is `public` (we need it for the cast in `IAMIdentityCenter`)

If no single protocol covers both `AWSSSOOIDC.*` and `AWSSSO.*` exceptions, document the fallback path (probably `String(describing: type(of: error))` for the type name and `nil` for the message — the mapping table handles unknowns gracefully).

- [ ] **Step 4: No commit; record findings only**

These notes flow into the adapter code in Tasks 1.3 and 2.3.

### Task 1.3: Implement `SDKErrorMapping` and `SDKOIDCClient`

**Files:**
- Create: `Packages/QuorraCore/Sources/IAMIdentityCenter/SDK/SDKErrorMapping.swift`
- Create: `Packages/QuorraCore/Tests/IAMIdentityCenterTests/SDK/SDKErrorMappingTests.swift`
- Create: `Packages/QuorraCore/Sources/IAMIdentityCenter/SDK/SDKOIDCClient.swift`

- [ ] **Step 1: Write the failing mapping tests**

```swift
// SDKErrorMappingTests.swift — tests for the pure error-classification table.
//
// No SDK imports — the mapper operates on (typeName, message) strings, so the
// test surface is string-in / enum-out. This is the entire point of structuring
// SDKErrorMapping as a pure function over a discriminator pair: SDK exception
// construction is undocumented/private, but classification is exhaustively
// testable in isolation.
import Testing
@testable import IAMIdentityCenter

@Suite struct SDKErrorMappingTests {
    // MARK: - OIDC table

    @Test func oidcInvalidClient() {
        #expect(SDKErrorMapping.mapOIDC(typeName: "InvalidClientException", message: nil) == .invalidClient)
    }

    @Test func oidcAuthorizationPending() {
        #expect(SDKErrorMapping.mapOIDC(typeName: "AuthorizationPendingException", message: nil) == .authorizationPending)
    }

    @Test func oidcSlowDown() {
        #expect(SDKErrorMapping.mapOIDC(typeName: "SlowDownException", message: nil) == .slowDown)
    }

    @Test func oidcAccessDenied() {
        #expect(SDKErrorMapping.mapOIDC(typeName: "AccessDeniedException", message: nil) == .accessDenied)
    }

    @Test func oidcExpiredToken() {
        #expect(SDKErrorMapping.mapOIDC(typeName: "ExpiredTokenException", message: nil) == .expiredDeviceCode)
    }

    @Test func oidcInvalidGrant() {
        #expect(SDKErrorMapping.mapOIDC(typeName: "InvalidGrantException", message: nil) == .invalidGrant)
    }

    @Test func oidcInvalidRequestCarriesMessage() {
        let mapped = SDKErrorMapping.mapOIDC(
            typeName: "InvalidRequestException",
            message: "Invalid start url provided"
        )
        guard case .awsError(let code, let desc) = mapped else {
            Issue.record("expected .awsError, got \(mapped)")
            return
        }
        #expect(code == "invalid_request")
        #expect(desc == "Invalid start url provided")
    }

    @Test func oidcUnknownFallsThrough() {
        let mapped = SDKErrorMapping.mapOIDC(typeName: "FutureSDKException", message: "msg")
        guard case .awsError(let code, _) = mapped else {
            Issue.record("expected .awsError, got \(mapped)")
            return
        }
        #expect(code == "unknown")
    }
}
```

- [ ] **Step 2: Run the tests — expect them to fail to compile** (no `SDKErrorMapping` yet)

Expected error: `cannot find 'SDKErrorMapping' in scope`. This is the red state that drives Step 3.

- [ ] **Step 3: Implement `SDKErrorMapping`**

```swift
// SDKErrorMapping.swift — containment boundary for AWS SDK exceptions.
//
// Two responsibilities, separated for testability:
//
//   1. `mapOIDC` / `mapPortal` are PURE FUNCTIONS over a (typeName, message)
//      discriminator pair. No SDK imports in their signatures — they're
//      exhaustively unit-testable in SDKErrorMappingTests with plain strings.
//
//   2. `extract(from:)` pulls the discriminator out of a thrown SDK exception
//      via whatever protocol the SDK exposes for that (see Phase 1 Notes).
//      It's small, has a benign fallback, and is exercised through the
//      adapters in production rather than tested directly.
//
// SDK version drift only affects `extract(from:)` and the type-name strings
// in the mapping table — the test surface is stable.
import Foundation
// NOTE: The exact protocol import depends on Task 1.2 Step 3 verification.
// Likely candidates: ClientRuntime, AWSClientRuntime, or smithy-swift's
// runtime. Adjust the import + the cast in extract(from:) accordingly.
import ClientRuntime

enum SDKErrorMapping {
    static func mapOIDC(typeName: String, message: String?) -> IAMIdentityCenterError {
        switch typeName {
        case "InvalidClientException":        return .invalidClient
        case "AuthorizationPendingException": return .authorizationPending
        case "SlowDownException":             return .slowDown
        case "AccessDeniedException":         return .accessDenied
        case "ExpiredTokenException":         return .expiredDeviceCode
        case "InvalidGrantException":         return .invalidGrant
        case "InvalidRequestException":
            return .awsError(code: "invalid_request", description: message)
        case "UnauthorizedClientException":
            return .awsError(code: "unauthorized_client", description: message)
        case "InternalServerException":
            return .awsError(code: "server_error", description: message)
        default:
            return .awsError(code: "unknown", description: message ?? typeName)
        }
    }

    /// Pulls a (typeName, message) discriminator out of an SDK exception.
    /// Falls back to the Swift type name + nil message when the error doesn't
    /// conform to a known SDK error protocol. Misclassification is benign —
    /// the mapping table's default case yields `.awsError("unknown", ...)`.
    static func extract(from error: any Error) -> (typeName: String, message: String?) {
        // Adjust per Task 1.2 Step 3 verification. The pattern below assumes
        // a ServiceError-shaped protocol with `typeName` + `message`; swap
        // property names if the SDK exposes different ones.
        if let svc = error as? ServiceError {
            return (svc.typeName ?? String(describing: type(of: error)), svc.message)
        }
        return (String(describing: type(of: error)), nil)
    }
}
```

> If Task 1.2 Step 3 found that no `ServiceError`-style protocol is `public`/usable, the fallback path (`String(describing: type(of: error))`) still produces a sensible discriminator like `"InvalidClientException"` for SDK exception types whose Swift type name matches the Smithy type name. In that case, the `if let svc = error as? ServiceError` branch is deleted and `extract` is one line. The mapping tests remain unchanged.

- [ ] **Step 4: Run the tests — all green**

Run `mcp__xcode__RunSomeTests` for `IAMIdentityCenterTests/SDKErrorMappingTests`.

- [ ] **Step 5: Write the adapter**

```swift
// SDKOIDCClient.swift — OIDCRequesting impl backed by AWSSSOOIDC.SSOOIDCClient.
//
// Region-bound at init (the SDK client's config carries region). Translates
// Quorra domain types ↔ SDK Input/Output. Errors flow through SDKErrorMapping.
//
// final class + @unchecked Sendable: SSOOIDCClient is a class with internal
// state (signer, retry strategy, HTTP client) but documented thread-safe.
// We do not mutate after init.
import Foundation
import AWSSSOOIDC

public final class SDKOIDCClient: OIDCRequesting, @unchecked Sendable {
    private let region: String
    private let client: SSOOIDCClient

    public init(region: String) async throws {
        self.region = region
        let config = try await SSOOIDCClient.SSOOIDCClientConfiguration(region: region)
        self.client = SSOOIDCClient(config: config)
    }

    /// Routes a thrown SDK error through the containment boundary.
    /// One line in every catch block keeps the boundary visible at every call site.
    private func mapped(_ error: any Error) -> IAMIdentityCenterError {
        let (typeName, message) = SDKErrorMapping.extract(from: error)
        return SDKErrorMapping.mapOIDC(typeName: typeName, message: message)
    }

    public func registerClient(
        clientName: String,
        scopes: [String]
    ) async throws -> StoredOIDCClient {
        let input = RegisterClientInput(
            clientName: clientName,
            clientType: "public",
            scopes: scopes.isEmpty ? nil : scopes
        )
        let output: RegisterClientOutput
        do { output = try await client.registerClient(input: input) }
        catch { throw mapped(error) }

        guard let clientId = output.clientId,
              let clientSecret = output.clientSecret
        else { throw IAMIdentityCenterError.malformedResponse("RegisterClient missing required fields") }

        return StoredOIDCClient(
            clientId: clientId,
            clientSecret: clientSecret,
            issuedAt: Date(timeIntervalSince1970: TimeInterval(output.clientIdIssuedAt)),
            secretExpiresAt: Date(timeIntervalSince1970: TimeInterval(output.clientSecretExpiresAt)),
            region: region,
            scopes: scopes
        )
    }

    public func startDeviceAuthorization(
        client storedClient: StoredOIDCClient,
        startUrl: URL,
        sessionName: String
    ) async throws -> (deviceCode: String, verification: DeviceVerification) {
        let input = StartDeviceAuthorizationInput(
            clientId: storedClient.clientId,
            clientSecret: storedClient.clientSecret,
            startUrl: startUrl.absoluteString
        )
        let output: StartDeviceAuthorizationOutput
        do { output = try await client.startDeviceAuthorization(input: input) }
        catch { throw mapped(error) }

        guard let deviceCode = output.deviceCode,
              let userCode = output.userCode,
              let vUri = output.verificationUri.flatMap(URL.init(string:)),
              let vUriComplete = output.verificationUriComplete.flatMap(URL.init(string:))
        else { throw IAMIdentityCenterError.malformedResponse("StartDeviceAuthorization missing required fields") }

        let verification = DeviceVerification(
            userCode: userCode,
            verificationUri: vUri,
            verificationUriComplete: vUriComplete,
            expiresAt: Date().addingTimeInterval(TimeInterval(output.expiresIn)),
            interval: TimeInterval(output.interval == 0 ? 5 : output.interval)
        )
        return (deviceCode, verification)
    }

    public func createToken(
        client storedClient: StoredOIDCClient,
        deviceCode: String,
        sessionName: String
    ) async throws -> StoredSSOToken {
        let input = CreateTokenInput(
            clientId: storedClient.clientId,
            clientSecret: storedClient.clientSecret,
            deviceCode: deviceCode,
            grantType: "urn:ietf:params:oauth:grant-type:device_code"
        )
        return try await runCreateToken(input: input, sessionName: sessionName, fallbackRefreshToken: nil)
    }

    public func refreshToken(
        client storedClient: StoredOIDCClient,
        refreshToken: String,
        sessionName: String
    ) async throws -> StoredSSOToken {
        let input = CreateTokenInput(
            clientId: storedClient.clientId,
            clientSecret: storedClient.clientSecret,
            grantType: "refresh_token",
            refreshToken: refreshToken
        )
        // Behavior match: hand-rolled OIDCClient set refreshToken = response.refreshToken
        // (no fallback). Preserve that semantic — if AWS returns no refresh token on a
        // refresh response, the next refresh will see refreshToken == nil and the actor's
        // refresh-failure path treats it as terminal. Do NOT silently substitute the
        // previous refresh token.
        return try await runCreateToken(input: input, sessionName: sessionName, fallbackRefreshToken: nil)
    }

    private func runCreateToken(
        input: CreateTokenInput,
        sessionName: String,
        fallbackRefreshToken: String?
    ) async throws -> StoredSSOToken {
        let output: CreateTokenOutput
        do { output = try await client.createToken(input: input) }
        catch { throw mapped(error) }

        guard let accessToken = output.accessToken
        else { throw IAMIdentityCenterError.malformedResponse("CreateToken missing accessToken") }

        return StoredSSOToken(
            accessToken: accessToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(output.expiresIn)),
            refreshToken: output.refreshToken ?? fallbackRefreshToken,
            issuedAt: Date(),
            region: region,
            sessionName: sessionName
        )
    }
}
```

- [ ] **Step 6: Build**

Run `mcp__xcode__BuildProject`. Expected: BUILD SUCCEEDED. Sendable warnings localized to `SDKOIDCClient` are acceptable (covered by `@unchecked Sendable`). Cross-module Sendable warnings → stop and triage.

### Task 1.4: Implement `SDKOIDCClientProvider`

**Files:**
- Create: `Packages/QuorraCore/Sources/IAMIdentityCenter/SDK/SDKOIDCClientProvider.swift`

- [ ] **Step 1: Write the provider**

```swift
// SDKOIDCClientProvider.swift — region-keyed cache of SDKOIDCClient instances.
import Foundation

public actor SDKOIDCClientProvider: OIDCClientProviding {
    private var clients: [String: SDKOIDCClient] = [:]

    public init() {}

    public func client(forRegion region: String) async throws -> any OIDCRequesting {
        if let cached = clients[region] { return cached }
        let fresh = try await SDKOIDCClient(region: region)
        clients[region] = fresh
        return fresh
    }
}
```

- [ ] **Step 2: Build**

Run `mcp__xcode__BuildProject`. Expected: BUILD SUCCEEDED.

### Task 1.5: Add `StubOIDCClientProvider` and the regression test

**Files:**
- Create: `Packages/QuorraCore/Tests/IAMIdentityCenterTests/Stubs/StubOIDCClientProvider.swift`
- Create: `Packages/QuorraCore/Tests/IAMIdentityCenterTests/RegionRoutingTests.swift`

- [ ] **Step 1: Write the recording stub provider**

```swift
// StubOIDCClientProvider.swift — test double that records every region request
// and returns a per-region StubOIDCRequesting so tests can assert routing.
import Foundation
@testable import IAMIdentityCenter

public actor StubOIDCClientProvider: OIDCClientProviding {
    public private(set) var regionRequests: [String] = []
    private var stubs: [String: StubOIDCRequesting] = [:]
    private let factory: @Sendable (String) -> StubOIDCRequesting

    public init(factory: @escaping @Sendable (String) -> StubOIDCRequesting) {
        self.factory = factory
    }

    public func client(forRegion region: String) async throws -> any OIDCRequesting {
        regionRequests.append(region)
        if let cached = stubs[region] { return cached }
        let stub = factory(region)
        stubs[region] = stub
        return stub
    }

    public func stub(forRegion region: String) -> StubOIDCRequesting? {
        stubs[region]
    }
}
```

- [ ] **Step 2: Write the regression test**

```swift
// RegionRoutingTests.swift — proves that signIn(region:) asks the provider for
// that exact region. This is the failing case in production today.
import Testing
import Foundation
@testable import IAMIdentityCenter

@Suite struct RegionRoutingTests {
    @Test func signInAsksProviderForSessionRegion() async throws {
        let provider = StubOIDCClientProvider(factory: { _ in StubOIDCRequesting() })
        let service = IdentityCenterService(
            keychain: InMemoryKeychainStore(),
            oidcClientProvider: provider
        )

        _ = try? await service.signIn(
            sessionName: "astrocompute",
            startUrl: URL(string: "https://asteroidcomputing.awsapps.com/start")!,
            region: "us-east-2",
            scopes: ["sso:account:access"],
            verificationHandler: { _ in }
        )

        let regions = await provider.regionRequests
        #expect(regions.contains("us-east-2"))
        #expect(regions.allSatisfy { $0 == "us-east-2" })
    }
}
```

- [ ] **Step 3: Run the test to confirm it fails to compile**

Run `mcp__xcode__RunSomeTests` for `IAMIdentityCenterTests/RegionRoutingTests`. Expected: COMPILE ERROR — `IdentityCenterService.init` does not yet take `oidcClientProvider`. This drives Task 1.6.

### Task 1.6: Switch `IdentityCenterService` to use the provider

**Files:**
- Modify: `Packages/QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService.swift`
- Modify: `Packages/QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService+Refresh.swift`
- Modify: `Packages/QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService+Polling.swift`

- [ ] **Step 1: Replace the stored OIDC client with the provider in `IdentityCenterService.swift`**

Replace:
```swift
internal let oidcClient: any OIDCRequesting
```
With:
```swift
internal let oidcClientProvider: any OIDCClientProviding
```

Update the init signature:
```swift
public init(
    keychain: any KeychainStore,
    oidcClientProvider: any OIDCClientProviding,
    portalClient: any PortalRequesting = PortalClient(),
    sleeper: any Sleeper = WallClockSleeper(),
    urlSession: URLSession = .shared
)
```
Store `oidcClientProvider` in place of `oidcClient`. Leave everything else (the AsyncStream creation, the timer maps) untouched.

- [ ] **Step 2: Targeted edit inside `ensureOIDCClient(region:scopes:clientName:)`**

In `IdentityCenterService.swift`, the method already has the cached-keychain-read path that returns early when the cache is valid. Do NOT delete that path. Replace only the single line that calls `registerClient`:

Replace:
```swift
let client = try await oidcClient.registerClient(clientName: clientName, scopes: scopes)
```
With:
```swift
let oidc = try await oidcClientProvider.client(forRegion: region)
let client = try await oidc.registerClient(clientName: clientName, scopes: scopes)
```

- [ ] **Step 3: Targeted edit inside `runSignIn(...)` for `startDeviceAuthorization`**

Replace:
```swift
let (deviceCode, verification) = try await oidcClient.startDeviceAuthorization(
    client: client,
    startUrl: startUrl,
    sessionName: sessionName
)
```
With:
```swift
let oidc = try await oidcClientProvider.client(forRegion: region)
let (deviceCode, verification) = try await oidc.startDeviceAuthorization(
    client: client,
    startUrl: startUrl,
    sessionName: sessionName
)
```

- [ ] **Step 4: Update `pollForToken(...)` in `+Polling.swift`**

The polling helper calls `self.oidcClient.createToken(...)`. The authoritative region for the poll is `client.region` (the `StoredOIDCClient` that bootstrapped this sign-in). Replace:
```swift
let token = try await oidcClient.createToken(
    client: client,
    deviceCode: deviceCode,
    sessionName: sessionName
)
```
With:
```swift
let oidc = try await oidcClientProvider.client(forRegion: client.region)
let token = try await oidc.createToken(
    client: client,
    deviceCode: deviceCode,
    sessionName: sessionName
)
```

- [ ] **Step 5: Update `runRefreshBody(...)` in `+Refresh.swift`**

Replace:
```swift
newToken = try await oidcClient.refreshToken(
    client: client,
    refreshToken: refreshToken,
    sessionName: sessionName
)
```
With:
```swift
let oidc = try await oidcClientProvider.client(forRegion: oldToken.region)
newToken = try await oidc.refreshToken(
    client: client,
    refreshToken: refreshToken,
    sessionName: sessionName
)
```

(The `client: StoredOIDCClient` already came from `ensureRefreshClient(region: oldToken.region)`, so the region is consistent.)

- [ ] **Step 6: Build**

Run `mcp__xcode__BuildProject`. Expected: BUILD FAILED — all the test files still construct `IdentityCenterService(oidcClient: ...)`. That's fine; Task 1.7 fixes them.

### Task 1.7: Update tests to use the provider

**Files:**
- Modify: every file under `Packages/QuorraCore/Tests/IAMIdentityCenterTests/` that constructs `IdentityCenterService(... oidcClient: ...)`. Grep first to enumerate.
- Modify: `Tests/QuorraAppTests/CredentialsModelTests.swift` (app target).

- [ ] **Step 1: Enumerate affected files**

```bash
grep -rln 'oidcClient:' Packages/QuorraCore/Tests/IAMIdentityCenterTests/ Tests/QuorraAppTests/
```

Expected hit list (use as a sanity check, not authoritative): `SignInTests.swift`, `SignOutTests.swift`, `SignOutCascadeTests.swift`, `ExpirationTimerTests.swift`, `RefreshTimerTests.swift`, `RefreshFailureTests.swift`, `TokenRotationTests.swift`, `AuthEventStreamTests.swift`, `LiveTokenTests.swift`, `LiveCredentialsTests.swift`, `MintEventStreamTests.swift`, `MintTimerTests.swift`, `RoleCredentialsTests.swift`, `SessionLockTests.swift`, `StatusTests.swift`, `ProfileStatusTests.swift`, `CredentialsModelTests.swift`.

- [ ] **Step 2: Add a helper in `Packages/QuorraCore/Tests/IAMIdentityCenterTests/Stubs/TestHelpers.swift`**

```swift
public func makeStubOIDCProvider(_ stub: StubOIDCRequesting) -> StubOIDCClientProvider {
    StubOIDCClientProvider(factory: { _ in stub })
}
```

- [ ] **Step 3: For each test file, replace `oidcClient: stub` with `oidcClientProvider: makeStubOIDCProvider(stub)`**

Use `mcp__xcode__XcodeGrep` + targeted edits, or a careful global replace if patterns are uniform. Spot-check that the build passes after each batch of ~5 files.

- [ ] **Step 4: Delete the `OIDCClient` reference in `StubOIDCRequesting.swift`'s usage example**

The docstring example shows `IdentityCenterService(keychain: keychain, oidcClient: stub)`. Update to:
```swift
let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(stub))
```

- [ ] **Step 5: Run the full test suite**

Run `mcp__xcode__RunAllTests`. Expected: every previously-passing test still passes, AND `RegionRoutingTests.signInAsksProviderForSessionRegion` is now GREEN.

### Task 1.8: Wire SDK provider into the app

**Files:**
- Modify: `App/quorraApp.swift`

- [ ] **Step 1: Replace the hardcoded-region OIDCClient with the SDK provider**

Current (line 9–13 of `App/quorraApp.swift`):
```swift
@State private var credentialsModel = CredentialsModel(
    service: IdentityCenterService(
        keychain: Keychain(accessGroup: KeychainAccessGroup.shared),
        oidcClient: OIDCClient(region: "us-east-1")
    )
)
```

New:
```swift
@State private var credentialsModel = CredentialsModel(
    service: IdentityCenterService(
        keychain: Keychain(accessGroup: KeychainAccessGroup.shared),
        oidcClientProvider: SDKOIDCClientProvider()
    )
)
```

- [ ] **Step 2: Build**

Run `mcp__xcode__BuildProject`. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Capture binary delta**

```bash
ls -lh "$(xcodebuild -showBuildSettings -workspace Quorra.xcworkspace -scheme Quorra | awk -F= '/ CONFIGURATION_BUILD_DIR /{print $2}' | xargs)"/quorra.app/Contents/MacOS/quorra
```

Record before/after binary size in this file's "Phase 1 Notes" section. "Before" = the most recent main-branch build pre-Phase-1.

### Task 1.9: Manually verify the bug fix

- [ ] **Step 1: Launch the app from Xcode (⌘R)**

- [ ] **Step 2: In a second terminal, stream logs**

```bash
log stream --style compact --predicate 'subsystem == "dev.ajbeck.quorra"'
```

- [ ] **Step 3: Sign in to the `astrocompute` session (us-east-2)**

Expected: device-code flow completes successfully. **Proof of fix:** in the log stream (or via `Console.app` → "URL Loading System" subsystem if needed), the SDK's outbound HTTPS calls hit `oidc.us-east-2.amazonaws.com`. The previous error (`invalid_request: Invalid start url provided`) does not occur.

- [ ] **Step 4: Sign in to a us-east-1 session if available**

Expected: also succeeds. Cross-region routing verified.

- [ ] **Step 5: Cycle a refresh**

Either wait until `expiresAt − refreshSkew` or temporarily lower `refreshSkew` via a debug toggle. Confirm refresh succeeds via the SDK (`.refreshed` event fires, new token persists).

### Task 1.10: Delete the hand-rolled OIDC transport

**Files (delete):**
- `Packages/QuorraCore/Sources/IAMIdentityCenter/OIDCClient.swift`
- `Packages/QuorraCore/Sources/IAMIdentityCenter/OIDCClient+Refresh.swift`
- `Packages/QuorraCore/Sources/IAMIdentityCenter/Wire/RegisterClient.swift`
- `Packages/QuorraCore/Sources/IAMIdentityCenter/Wire/StartDeviceAuthorization.swift`
- `Packages/QuorraCore/Sources/IAMIdentityCenter/Wire/CreateToken.swift`
- `Packages/QuorraCore/Sources/IAMIdentityCenter/Wire/RefreshToken.swift`
- `Packages/QuorraCore/Tests/IAMIdentityCenterTests/OIDCClientTests.swift`
- `Packages/QuorraCore/Tests/IAMIdentityCenterTests/OIDCClientRefreshTests.swift`

> Note: `Wire/AWSServiceErrorResponse.swift`, `Wire/OAuthErrorResponse.swift`, `Wire/Wire.swift`, and `HTTPErrorMapping.swift` are kept until Phase 2 — `PortalClient` still references them.

- [ ] **Step 1: Grep for residual references before deleting**

```
mcp__xcode__XcodeGrep
  pattern: \bOIDCClient\b|\bWire\.RegisterClient|\bWire\.StartDeviceAuth|\bWire\.CreateToken|\bWire\.RefreshToken
  outputMode: files_with_matches
```

Expected hits: only the files listed for deletion plus possibly the docstring example in `StubOIDCRequesting.swift` (already updated in Task 1.7 Step 4). If anything else appears, fix it before deleting.

- [ ] **Step 2: Delete each file via `mcp__xcode__XcodeRM`** (one call per file, `deleteFiles: true`)

- [ ] **Step 3: Build & run tests**

Run `mcp__xcode__BuildProject` then `mcp__xcode__RunAllTests`. Expected: all green.

### Phase 1 commit checkpoint

End Phase 1 with **one or two commits** that cover the SDK adoption *and* the bug fix. Suggested slicing:

- One commit covering Tasks 1.1–1.9 (the migration itself, end-to-end working with manual verification done).
- A second commit for Task 1.10 (the deletion of hand-rolled OIDC code) — kept separate so the deletion is reviewable in isolation and trivially revertable if anything surfaces post-merge.

Whichever slicing you pick, the headline commit should describe both the SDK adoption *and* the user-facing bug fix it ships — this is what lands on `main` to fix the production issue. `feat(iam-identity-center):` or `refactor(iam-identity-center):` type. Conventional-commits body should mention the previous `invalid_request: Invalid start url provided` failure mode and the per-region routing that replaces it.

---

## Phase 2 — SDK-Backed Portal (incl. sign-out logout)

> **Goal:** replace `PortalClient` and `PortalLogout` with an SDK-backed `SDKPortalClient` that conforms to `PortalRequesting`. The existing `PortalRequesting` protocol already takes `region:` per call, so the adapter caches its own per-region `SSOClient` map internally — no `PortalClientProviding` is needed. Logout moves into `PortalRequesting` so `+SignOut.swift` can stop instantiating `PortalLogout` directly.

### Task 2.1: Add `logout` to `PortalRequesting`

**Files:**
- Modify: `Packages/QuorraCore/Sources/IAMIdentityCenter/PortalRequesting.swift`
- Modify: `Packages/QuorraCore/Sources/IAMIdentityCenter/PortalClient.swift` (transitional conformance — kept for one task until Phase 2 ends)
- Modify: `Packages/QuorraCore/Tests/IAMIdentityCenterTests/Stubs/StubPortalRequesting.swift`

- [ ] **Step 1: Add the verb to the protocol**

```swift
public protocol PortalRequesting: Sendable {
    // ... existing verbs ...

    /// Invalidates the SSO access token server-side (best-effort).
    ///
    /// Hits `portal.sso.<region>.amazonaws.com`. Sign-out treats failure as advisory
    /// (emits `.signOutServerSideFailed`) — it does not throw to the caller.
    func logout(accessToken: String, region: String) async throws
}
```

- [ ] **Step 2: Implement on the existing `PortalClient` (transitional)**

Move the body of `PortalLogout.logout(accessToken:region:)` into `PortalClient` so the protocol conformance holds while Phase 2 is in progress. The implementation is mechanical — copy the URLRequest construction from `PortalLogout.swift` verbatim, using `self.urlSession`.

> This transitional impl is deleted in Task 2.5 when `SDKPortalClient` takes over.

- [ ] **Step 3: Add the verb to `StubPortalRequesting`**

```swift
private(set) var logoutCallCount = 0
var nextLogoutResult: Result<Void, Error> = .success(())

func logout(accessToken: String, region: String) async throws {
    logoutCallCount += 1
    try nextLogoutResult.get()
}
```

- [ ] **Step 4: Build**

Expected: BUILD SUCCEEDED.

### Task 2.2: Update `+SignOut.swift` to use `portalClient.logout`

**Files:**
- Modify: `Packages/QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService+SignOut.swift`

- [ ] **Step 1: Replace the `PortalLogout` block**

Current (lines 123–131 in `+SignOut.swift`):
```swift
let portalLogout = PortalLogout(urlSession: self.urlSession)
do {
    try await portalLogout.logout(accessToken: token.accessToken, region: token.region)
} catch {
    self.eventContinuation.yield(.signOutServerSideFailed(sessionName: sessionName))
}
```
New:
```swift
do {
    try await self.portalClient.logout(accessToken: token.accessToken, region: token.region)
} catch {
    self.eventContinuation.yield(.signOutServerSideFailed(sessionName: sessionName))
}
```

- [ ] **Step 2: Build & run tests**

Expected: existing sign-out tests still pass (they inject `StubPortalRequesting` which now has a `logout` stub).

### Task 2.3: Extend `SDKErrorMapping` for Portal exceptions

**Files:**
- Modify: `Packages/QuorraCore/Sources/IAMIdentityCenter/SDK/SDKErrorMapping.swift`
- Modify: `Packages/QuorraCore/Tests/IAMIdentityCenterTests/SDK/SDKErrorMappingTests.swift`

- [ ] **Step 1: Add failing Portal mapping tests**

```swift
// Append to SDKErrorMappingTests.swift — same string-in/enum-out shape as the
// OIDC tests in Phase 1. No SDK imports.

@Test func portalForbiddenMapsToRoleNotAssigned() {
    #expect(SDKErrorMapping.mapPortal(typeName: "ForbiddenException", message: nil) == .roleNotAssigned)
}

@Test func portalResourceNotFoundMapsToAccountNotFound() {
    #expect(SDKErrorMapping.mapPortal(typeName: "ResourceNotFoundException", message: nil) == .accountNotFound)
}

@Test func portalUnauthorizedMapsToTokenExpired() {
    #expect(SDKErrorMapping.mapPortal(typeName: "UnauthorizedException", message: nil) == .tokenExpired)
}

@Test func portalTooManyRequestsCarriesMessage() {
    let mapped = SDKErrorMapping.mapPortal(typeName: "TooManyRequestsException", message: "throttled")
    guard case .awsError(let code, let desc) = mapped else {
        Issue.record("expected .awsError, got \(mapped)")
        return
    }
    #expect(code == "too_many_requests")
    #expect(desc == "throttled")
}

@Test func portalUnknownFallsThrough() {
    let mapped = SDKErrorMapping.mapPortal(typeName: "FutureSDKException", message: nil)
    guard case .awsError(let code, _) = mapped else {
        Issue.record("expected .awsError")
        return
    }
    #expect(code == "unknown")
}
```

- [ ] **Step 2: Run — expect compile failure on `mapPortal` (doesn't exist yet)**

- [ ] **Step 3: Add the Portal mapper**

```swift
extension SDKErrorMapping {
    static func mapPortal(typeName: String, message: String?) -> IAMIdentityCenterError {
        switch typeName {
        case "ForbiddenException":        return .roleNotAssigned
        case "ResourceNotFoundException": return .accountNotFound
        case "UnauthorizedException":     return .tokenExpired
        case "TooManyRequestsException":
            return .awsError(code: "too_many_requests", description: message)
        case "InvalidRequestException":
            return .awsError(code: "invalid_request", description: message)
        default:
            return .awsError(code: "unknown", description: message ?? typeName)
        }
    }
}
```

Note: `extract(from:)` from Phase 1 already handles both OIDC and Portal exceptions — it's a single helper keyed on the SDK's error-discrimination protocol, not on the specific service.

- [ ] **Step 4: Run tests — all green**

### Task 2.4: Implement `SDKPortalClient`

**Files:**
- Create: `Packages/QuorraCore/Sources/IAMIdentityCenter/SDK/SDKPortalClient.swift`

- [ ] **Step 1: Write the adapter**

```swift
// SDKPortalClient.swift — PortalRequesting impl backed by AWSSSO.SSOClient.
//
// Caches one SSOClient per region internally. The existing PortalRequesting
// protocol takes region: per call, so no external provider is needed.
//
// actor: serialize access to the per-region cache. SSOClient itself is
// documented thread-safe; the cache mutation is what needs isolation.
import Foundation
import AWSSSO

public actor SDKPortalClient: PortalRequesting {
    private var clients: [String: SSOClient] = [:]

    public init() {}

    private func client(forRegion region: String) async throws -> SSOClient {
        if let cached = clients[region] { return cached }
        let config = try await SSOClient.SSOClientConfiguration(region: region)
        let fresh = SSOClient(config: config)
        clients[region] = fresh
        return fresh
    }

    /// Routes a thrown SDK error through the containment boundary.
    private func mapped(_ error: any Error) -> IAMIdentityCenterError {
        let (typeName, message) = SDKErrorMapping.extract(from: error)
        return SDKErrorMapping.mapPortal(typeName: typeName, message: message)
    }

    public func listAccounts(accessToken: String, region: String) async throws -> [PortalAccount] {
        let sso = try await client(forRegion: region)
        var accounts: [PortalAccount] = []
        var nextToken: String? = nil
        repeat {
            let input = ListAccountsInput(accessToken: accessToken, nextToken: nextToken)
            let output: ListAccountsOutput
            do { output = try await sso.listAccounts(input: input) }
            catch { throw mapped(error) }

            let page = (output.accountList ?? []).compactMap { info -> PortalAccount? in
                guard let id = info.accountId else { return nil }
                return PortalAccount(accountId: id, accountName: info.accountName, emailAddress: info.emailAddress)
            }
            accounts.append(contentsOf: page)
            nextToken = output.nextToken
        } while nextToken != nil
        return accounts
    }

    public func listAccountRoles(accessToken: String, accountId: String, region: String) async throws -> [PortalRole] {
        let sso = try await client(forRegion: region)
        var roles: [PortalRole] = []
        var nextToken: String? = nil
        repeat {
            let input = ListAccountRolesInput(accessToken: accessToken, accountId: accountId, nextToken: nextToken)
            let output: ListAccountRolesOutput
            do { output = try await sso.listAccountRoles(input: input) }
            catch { throw mapped(error) }

            let page = (output.roleList ?? []).compactMap { info -> PortalRole? in
                guard let acct = info.accountId, let name = info.roleName else { return nil }
                return PortalRole(accountId: acct, roleName: name)
            }
            roles.append(contentsOf: page)
            nextToken = output.nextToken
        } while nextToken != nil
        return roles
    }

    public func getRoleCredentials(
        accessToken: String,
        accountId: String,
        roleName: String,
        region: String
    ) async throws -> MintedCredential {
        let sso = try await client(forRegion: region)
        let input = GetRoleCredentialsInput(
            accessToken: accessToken,
            accountId: accountId,
            roleName: roleName
        )
        let output: GetRoleCredentialsOutput
        do { output = try await sso.getRoleCredentials(input: input) }
        catch { throw SDKErrorMapping.mapPortal(error) }

        guard let creds = output.roleCredentials,
              let accessKeyId = creds.accessKeyId,
              let secretAccessKey = creds.secretAccessKey,
              let sessionToken = creds.sessionToken
        else { throw IAMIdentityCenterError.malformedResponse("GetRoleCredentials missing required fields") }

        // Portal expiration is Unix MILLISECONDS — see Phase 1 Task 1.2 verification notes.
        return MintedCredential(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(creds.expiration) / 1000.0)
        )
    }

    public func logout(accessToken: String, region: String) async throws {
        let sso = try await client(forRegion: region)
        let input = LogoutInput(accessToken: accessToken)
        do { _ = try await sso.logout(input: input) }
        catch { throw SDKErrorMapping.mapPortal(error) }
    }
}
```

> Returns `MintedCredential` — the actor (`+RoleCredentials.swift:178`) attaches provenance (`accountId`, `roleName`, `region`, `sessionName`, `issuedAt`) to build the persisted `RoleCredentials`.

- [ ] **Step 2: Build**

Expected: BUILD SUCCEEDED. Adjust Input/Output type spellings per Task 1.2 notes if the SDK uses different ones.

### Task 2.5: Wire `SDKPortalClient` in the app and delete the hand-rolled Portal

**Files:**
- Modify: `App/quorraApp.swift`

**Files (delete):**
- `Packages/QuorraCore/Sources/IAMIdentityCenter/PortalClient.swift`
- `Packages/QuorraCore/Sources/IAMIdentityCenter/PortalLogout.swift`
- `Packages/QuorraCore/Sources/IAMIdentityCenter/Wire/GetRoleCredentials.swift`
- `Packages/QuorraCore/Sources/IAMIdentityCenter/Wire/ListAccounts.swift`
- `Packages/QuorraCore/Sources/IAMIdentityCenter/Wire/ListAccountRoles.swift`
- `Packages/QuorraCore/Sources/IAMIdentityCenter/Wire/AWSServiceErrorResponse.swift`
- `Packages/QuorraCore/Sources/IAMIdentityCenter/Wire/OAuthErrorResponse.swift`
- `Packages/QuorraCore/Sources/IAMIdentityCenter/Wire/Wire.swift`
- `Packages/QuorraCore/Sources/IAMIdentityCenter/HTTPErrorMapping.swift`
- `Packages/QuorraCore/Tests/IAMIdentityCenterTests/PortalClientTests.swift`

- [ ] **Step 1: Update the app wiring**

```swift
@State private var credentialsModel = CredentialsModel(
    service: IdentityCenterService(
        keychain: Keychain(accessGroup: KeychainAccessGroup.shared),
        oidcClientProvider: SDKOIDCClientProvider(),
        portalClient: SDKPortalClient()
    )
)
```

- [ ] **Step 2: Grep for residual references before deleting**

```
mcp__xcode__XcodeGrep
  pattern: \bPortalClient\b|\bPortalLogout\b|\bHTTPErrorMapping\b|\bWire\.GetRoleCred|\bWire\.ListAccounts|\bWire\.ListAccountRoles|\bWire\.AWSService|\bWire\.OAuth
  outputMode: files_with_matches
```

Expected hits: only the files listed for deletion. If anything else appears, fix it first.

- [ ] **Step 3: Delete each file via `mcp__xcode__XcodeRM`**

- [ ] **Step 4: Manually verify**

Launch the app. Sign in to a session in any region. Use a profile to mint role credentials. Sign out. Confirm via `log stream` that all outbound calls go to `portal.sso.<region>.amazonaws.com`.

- [ ] **Step 5: Run the full test suite**

Run `mcp__xcode__RunAllTests`. Expected: all green.

### Phase 2 commit checkpoint

End Phase 2 with **one commit** that captures the Portal migration end-to-end: protocol extended with `logout`, `SDKPortalClient` wired in production, `+SignOut.swift` updated, and hand-rolled Portal + wire models + `HTTPErrorMapping` deleted. `refactor(iam-identity-center):` type. If `logout`-hoisting feels like a separable unit reviewers would want to see in isolation, split it as a precursor commit; otherwise one is fine.

---

## Phase 3 — Cleanup

### Task 3.1: Drop the unused `urlSession` parameter from `IdentityCenterService.init`

**Files:**
- Modify: `Packages/QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService.swift`
- Modify: test files that pass `urlSession:`

- [ ] **Step 1: Confirm `urlSession` is unused inside the actor**

```
mcp__xcode__XcodeGrep
  pattern: self\.urlSession
  outputMode: content
```

Expected: zero hits (Phase 2 Task 2.2 removed the last user).

- [ ] **Step 2: Remove `urlSession: URLSession = .shared` from the init**

Also remove the `internal let urlSession: URLSession` stored property and its assignment.

- [ ] **Step 3: Update call sites in tests**

```
mcp__xcode__XcodeGrep
  pattern: urlSession:
  outputMode: files_with_matches
```

Strip the `urlSession:` argument from every `IdentityCenterService(...)` constructor. (Test files that use `StubURLProtocol.makeSession()` keep that helper for the wire-level tests that still exist *outside* `IdentityCenterService` — confirm via grep.)

- [ ] **Step 4: Build & test**

Expected: BUILD SUCCEEDED, all tests green.

### Task 3.2: Prune obsolete `IAMIdentityCenterError` cases

**Files:**
- Modify: `Packages/QuorraCore/Sources/IAMIdentityCenter/Errors.swift`
- Modify: `Packages/QuorraCore/Sources/IAMIdentityCenter/Errors+LocalizedError.swift`

- [ ] **Step 1: Audit which obsolete cases still appear**

```
mcp__xcode__XcodeGrep
  pattern: \.httpStatus|\.network\(
  outputMode: content
```

Candidate removals (verify zero hits each):
- `case httpStatus(Int, body: String?)` — was thrown only by `HTTPErrorMapping`.
- `case network(URLError)` — only meaningful when we owned URLSession transport.

- [ ] **Step 2: Remove zero-hit cases from `Errors.swift` AND from `Errors+LocalizedError.swift`**

Removing only from one will be a compile error.

- [ ] **Step 3: Build & test**

Expected: all green. If a test asserted on a removed case, replace with `.awsError(...)` (the new shape).

### Task 3.3: Update docs

**Files:**
- Modify: `CLAUDE.md` ("SSO Flow" section)
- Modify: `docs/IAMIdentityCenterPlan.html`
- Modify: `README.md` (onboarding section)

- [ ] **Step 1: In `CLAUDE.md`, update the "SSO Flow" section**

Replace:
> Quorra implements the **full SSO OIDC device-code flow natively** — it does not shell out to `aws sso login`. The point of the tool is to own this flow.

With:
> Quorra implements the **full SSO OIDC device-code flow natively** — it does not shell out to `aws sso login`. The wire-level OIDC and Portal calls go through the official **AWS SDK for Swift** (`AWSSSOOIDC`, `AWSSSO`), wrapped behind our own `OIDCRequesting` / `PortalRequesting` protocols. Lifecycle (timers, refresh, mint, Keychain storage, events) is Quorra's own actor.

- [ ] **Step 2: In `docs/IAMIdentityCenterPlan.html`, note the transport migration**

Add a section/callout stating that the OIDC and Portal transports were migrated to AWS SDK for Swift on 2026-05-XX with a link back to this plan file.

- [ ] **Step 3: In `README.md`, add an onboarding note about the Smithy plugin trust gate**

(Per Phase 0 Notes — the first build on a fresh clone needs an interactive ⌘B in Xcode to accept the `SmithyCodeGeneratorPlugin` trust prompt; headless / MCP builds fail until this is done once.)

Example bullet under a "First-time setup" or "Local development" heading:
> **First build only:** open `Quorra.xcworkspace` in Xcode and run a build interactively (⌘B). Xcode will prompt to trust and enable `SmithyCodeGeneratorPlugin` (a transitive dependency of `aws-sdk-swift`). Click **Trust & Enable**. Headless builds (CI, MCP) will then work for this checkout.

### Phase 3 commit checkpoint

End Phase 3 with **one or two commits**. Natural slicing:

- One commit for Tasks 3.1 + 3.2 (code cleanup — `urlSession` removal + error case pruning), `chore(iam-identity-center):` type.
- One commit for Task 3.3 (docs), `docs:` type.

If the cleanup feels small enough to bundle with the docs update, one commit is fine.

---

## Phase 0 Notes (recorded during spike)

### Task 0.1 — SPM dependency add (2026-05-20)

- **Actual package path:** `Packages/QuorraCore/Package.swift` (early plan drafts used `QuorraCore/Package.swift`; that's incorrect — use `Packages/QuorraCore/...` everywhere).
- **`aws-sdk-swift` resolved version:** **1.7.1**
- **Key transitive deps resolved (in workspace `Package.resolved`):**
  - `smithy-swift` 0.207.0
  - `aws-crt-swift` 0.58.1
  - `swift-nio` 2.99.0 + nio-ssl 2.37.0 + nio-http2 1.43.0 + nio-transport-services 1.28.0 + nio-extras 1.34.0
  - `swift-crypto` 4.5.0 + swift-certificates 1.19.1 + swift-asn1 1.7.0
  - `async-http-client` 1.33.1
  - `swift-log` 1.12.0, `swift-collections` 1.5.1, `swift-atomics` 1.3.0, `swift-distributed-tracing` 1.4.1, `swift-service-lifecycle` 2.11.0, `swift-http-types` 1.5.1, `swift-http-structured-headers` 1.7.0
  - Total transitive count: ~26 packages.
- **Build result:** BUILD SUCCEEDED in ~112s (warm SourcePackages cache after first resolution). Zero warnings.
- **Version-pinning policy:** `Package.resolved` is currently gitignored. The Phase 0 follow-up step (above) un-ignores the workspace `Package.resolved` so the lockfile travels with the repo.
- **SmithyCodeGeneratorPlugin trust gate:** the first build on each developer's machine fails with `Plugin "SmithyCodeGeneratorPlugin" from package "smithy-swift" must be enabled before it can be used`. The MCP/headless build cannot accept the trust prompt — the developer must run an interactive ⌘B in Xcode UI once, click **Trust & Enable**, then headless builds work. **Phase 3 Task 3.3 adds this to the README.**

### Task 0.2 — SKIPPED

Originally specified a throwaway `_SpikeRemoveMe.swift` to import the SDK and instantiate a config/client. **Skipped on 2026-05-20** — Task 0.1 already proved resolution, plugin trust, and linkage; the remaining unknowns (exact type spellings, Sendable behavior) are discovered when we write the real adapter in Phase 1 with the compiler as the verifier. Phase 1 Task 1.2 is the verification step that replaces this.

**Operational rule for Phase 1+:** trust the AWS SDK for Swift docs (via the `mcp__aws-documentation__*` MCP) for type names and signatures; let Xcode flag any mismatches at build time. Don't preemptively grep SDK checkouts to confirm names.

### Task 0.3 — Gate review (2026-05-20)

- BUILD SUCCEEDED ✅
- App launches sandboxed (verified during Scope B chunk 6b development on same workspace) ✅
- Zero warnings introduced by the SDK link ✅
- Plugin trust documented as a one-time onboarding step ⚠️ (action: Phase 3 Task 3.3)
- Binary delta: deferred to Phase 1 Task 1.8 Step 3 (no SDK code is actually imported until then)

**Decision:** PROCEED to Phase 1.

---

## Phase 1 Notes (recorded during Phase 1 work)

### Task 1.2 — SDK type verification (2026-05-20)

**Source: AWS SDK for Swift Developer Guide.**

- **Client configuration pattern** (confirmed from [config-code.html](https://docs.aws.amazon.com/sdk-for-swift/latest/developer-guide/config-code.html)):
  - Convenience init: `try ServiceClient(region: "<region>")` — **synchronous, throws**.
  - Full config form: `try await ServiceClient.ServiceClientConfiguration(region: "<region>")` — **async throws** — pass into `ServiceClient(config: config)`.
  - Same pattern applies to all services, so `SSOOIDCClient` and `SSOClient` both follow it.
  - The plan's Task 1.3 code uses the async config form; that's fine but the convenience init would also work. Stick with the plan's form for explicitness and future-proofing (custom retry/logging).
- **Portal expiration unit** (confirmed from [API_RoleCredentials.html](https://docs.aws.amazon.com/singlesignon/latest/PortalAPIReference/API_RoleCredentials.html) + existing Quorra code at `PortalClient.swift:112,137` and `Wire/GetRoleCredentials.swift:7,16`):
  - `RoleCredentials.expiration` is **Unix milliseconds** (typed `Long` in the API ref, `Int64` in current Quorra code). Divide by 1000.0 when converting to `Date(timeIntervalSince1970:)`. The plan's Phase 2 `SDKPortalClient` already does this — verified.
- **Per-API Input/Output type spellings (OIDC):** not pinned from docs (AWS Swift SDK DocC isn't on `docs.aws.amazon.com`; the Apple DocumentationSearch MCP doesn't index third-party Swift packages). Will let the compiler verify in Task 1.3 — per the Phase 0 operational rule. The plan's spellings (`RegisterClientInput`, `StartDeviceAuthorizationInput`, `CreateTokenInput`, and corresponding `Output` types) follow the standard `aws-sdk-swift` Smithy code-gen convention; mismatches will surface as compile errors.
- **Error-discrimination protocol:** not pinned from docs. Will discover at compile time in Task 1.3 — the `SDKErrorMapping.extract(from:)` fallback path (`String(describing: type(of: error))`) yields a sensible discriminator even if no `ServiceError`-style protocol is publicly importable, so the failure mode is benign. If `ClientRuntime.ServiceError` doesn't exist, the `if let svc = error as? ServiceError` branch is deleted and `extract` is one line. **Resolved (Task 1.3):** kept the one-line fallback; the SDK's generated exception Swift type names match the Smithy type names, so `String(describing: type(of: error))` is sufficient. No `ClientRuntime` import needed.

### Task 1.7 — test-suite stubbing seam (decision: 2026-05-22)

**Discovery:** the plan's Task 1.7 assumed the IAM test suite injects a protocol-level `StubOIDCRequesting`. In reality ~14 files construct a **real `OIDCClient(region:, urlSession: StubURLProtocol.makeSession())`** and stub at the **HTTP level** via `StubURLProtocol`. Two populations:
- **Placeholder-only** (`OIDCClient` constructed but never invoked — `status`/timer/mint/sign-out tests): trivially swap to `oidcClientProvider: makeStubOIDCProvider(StubOIDCRequesting())`.
- **Wire-driving** (`LiveTokenTests`, `SignInTests`, `RefreshFailureTests`, `RefreshTimerTests`, `TokenRotationTests`, `AuthEventStreamTests`, `ExpirationTimerTests`): register `/client/register`, `/device_authorization`, `/token` responses and expect the actor to hit them. These cannot survive the SDK swap — the SDK doesn't route through `StubURLProtocol`.

**Decision — Apple best practice (Option 1):** convert the wire-driving behavior tests from HTTP-level (`StubURLProtocol`) to **protocol-level (`StubOIDCRequesting`)** stubbing, injected through the provider seam. Rationale (Apple *Engineering for Testability*, WWDC 2017; echoed in the Swift Testing docs and already quoted in `OIDCRequesting.swift`): *test the code you own, not your dependencies*, and *inject test doubles at the seam closest to the code under test*. Once the SDK owns OIDC wire encoding, a `StubURLProtocol` test is testing AWS's code; the correct seam is the `OIDCRequesting` protocol boundary. The pure wire-encoding tests `OIDCClientTests` / `OIDCClientRefreshTests` are deleted (Task 1.10) — they test code Quorra no longer owns.

Coalescing note: the actor's single-flight refresh (`+Refresh.swift`) is robust to instant stubs — coalescing is driven by the `keychain.readRecord` actor suspension in `performLiveToken` (a second caller enters during that suspension and `startInlineRefresh` re-checks `inFlightRefresh` before awaiting), NOT by network latency. So `concurrentLiveTokenCallsCoalesce` / `refreshNowCoalesces` convert cleanly: set a single canned refresh result and assert `stub.refreshCallCount == 1`.

### Task 1.3 correction — refreshToken behavior (found during Task 1.7, 2026-05-22)

The plan's `SDKOIDCClient.refreshToken` code block (and its comment) was **wrong about the existing behavior** and I initially copied it. The real hand-rolled `OIDCClient+Refresh.swift` does two refresh-specific things the plan omitted; the SDK adapter must preserve both (verified against the actual code + RFC 6749 §10.4 + the D14/D18 docstrings):

1. **Terminal-error remap (D14):** `invalid_grant` → `.refreshTokenRejected`, `invalid_client` → `.refreshClientInvalid`. The actor's `handleRefreshFailure` treats *only* those two as terminal (clears the dead refresh token / forces re-registration). The SDK adapter's generic `mapOIDC` yields `.invalidGrant` / `.invalidClient`, so `refreshToken` re-maps them in its catch block. (The `createToken` path keeps the generic mapping — the remap is refresh-only.)
2. **Refresh-token rotation fallback (D18 / RFC 6749 §10.4):** `output.refreshToken ?? <passed-in refreshToken>`. The plan's comment claimed the hand-rolled code used "no fallback" — that's a misread of line 55 (`response.refreshToken ?? refreshToken`). Without the fallback, the first refresh where AWS doesn't rotate the token nils the stored refresh token and forces an unnecessary re-sign-in. `createToken` correctly uses `fallbackRefreshToken: nil`.

Both are now implemented via a shared `makeToken(from:fallbackRefreshToken:sessionName:)` helper in `SDKOIDCClient`.

### Task 1.7/1.8 results (2026-05-22)

- Full suite: **475 passed, 0 failed, 1 skipped** (the skip is the pre-existing `AWSConfigINITests/FileIOTests/lockTimeoutThrownWhenLockHeld`, unrelated to this work). `RegionRoutingTests.signInAsksProviderForSessionRegion` is green.
- Test seam additions: `StubOIDCRequesting` gained `init(registerRegion:)` + `setNextRegisterResult` / `setNextStartDeviceAuthorizationResult` / `setNextCreateTokenResult`; `TestHelpers` gained `makeStubOIDCProvider`, `makeStoredClient`, `makeVerification`. Wire-driving suites (`SignInTests`, `LiveTokenTests`, `RefreshFailureTests`, `RefreshTimerTests`, `ExpirationTimerTests`, `AuthEventStreamTests`) converted to protocol-level stubbing; placeholder suites swapped to a no-op stub provider.
  - `RegionRoutingTests` subtlety: `pollForToken` keys its provider lookup off `client.region` (the registered client's region). The stub now embeds the requested region into its registered client (`init(registerRegion:)`) so all lookups stay on one region — mirroring the production SDK adapter, which embeds the region into the `StoredOIDCClient` it returns from `registerClient`.
- App wired: `App/quorraApp.swift` now injects `SDKOIDCClientProvider()`.
- **Binary delta (Task 1.8 Step 3):** not separately captured. The SDK framework weight already landed in Phase 0 (the link was verified there before any adapter code existed — see Phase 0 Task 0.3). Phase 1 adds only the thin adapter/provider Swift sources, so the Phase-1-specific delta over the Phase-0 baseline is negligible. A precise byte count was skipped (no clean pre-Phase-0 main build artifact on hand) as low-value.

---

## Self-Review Checklist

- [x] **Spec coverage:** every requirement from the chat — fix the bug, adopt SDK, factory-per-region for OIDC, drop hand-rolled code — has a phase or task.
- [x] **Bug fix lands in Phase 1**, atomically with SDK adoption. No transitional state where the bug is fixed but the SDK isn't in use.
- [x] **Asymmetric seams:** OIDC gets `OIDCClientProviding` because its existing protocol has no `region:` parameter; Portal does not, because `PortalRequesting` already takes `region:` per call.
- [x] **Type consistency:** `OIDCClientProviding.client(forRegion:)` is the same signature in protocol, stub, SDK impl, and all call sites.
- [x] **No placeholders:** every step has either real code or an exact tool command + expected result.
- [x] **Each task self-contained:** an executor reading task N out of order has the file paths and code blocks they need.
- [x] **Commit policy explicit, not prescriptive:** the plan states a commit policy up front and marks suggested checkpoints at phase boundaries, but does not hardcode `git add` paths or commit messages — the developer slices commits at the logical units they actually reached.
- [x] **Containment boundary is unit-testable without SDK mocks:** `SDKErrorMapping.mapOIDC` and `mapPortal` are pure `(typeName: String, message: String?) → IAMIdentityCenterError` functions. The test file imports only `IAMIdentityCenter` and never constructs an SDK exception. SDK type extraction is isolated to `extract(from:)` and has a benign fallback.

---

## Risks & Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| AWS CRT linker / sandbox failure | Low (Phase 0 cleared the gate) | Phase 0 gate passed; the SDK is linked and the app launches |
| SDK type/initializer names differ from this plan | Medium | Task 1.2 verifies against the resolved version (1.7.1) before any adapter code is written |
| Sendable strict-mode warnings on SDK clients | Medium | Adapters are `final class … @unchecked Sendable` at the boundary; documented thread-safety |
| Refresh-token semantics differ between hand-rolled and SDK | Low | Behavior preserved in `SDKOIDCClient.refreshToken` (no fallback to old refresh token); one manual refresh after Phase 1 to confirm |
| Binary size growth unacceptable | Low | Phase 1 Task 1.8 Step 3 records the delta; rollback path stays open until Task 1.10 |
| Sign-out test rewrite churn (logout now on `PortalRequesting`) | Low | `StubPortalRequesting` gains a `logout` stub in Task 2.1; existing sign-out tests pick it up without per-test rewrites |
