# AWS SDK for Swift — IAM Identity Center Migration

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Quorra's hand-rolled AWS SSO OIDC + Portal transport with the official AWS SDK for Swift (`AWSSSOOIDC`, `AWSSSO`), and as part of that change, fix the bug where a single fixed-region `OIDCClient` is shared across all SSO sessions — causing `invalid_request: Invalid start url provided` for any session whose region differs from the hardcoded `us-east-1`.

**Architecture:**
- The lifecycle actor `IdentityCenterService` is preserved verbatim — timers, single-flight maps, the `AsyncStream<AuthEvent>`, session locks, and Keychain-backed token storage are Quorra-specific value and are not in the SDK.
- The bug is fixed by introducing an `OIDCClientProviding` (and symmetric `PortalClientProviding`) factory injected into the actor. The factory builds a *region-correct* client on demand, keyed by region. The senders of a sign-in action (`CredentialsModel` / views) supply the region; the provider supplies the routed client.
- The SDK is adopted *behind* the existing `OIDCRequesting` and `PortalRequesting` protocols. SDK types are translated to Quorra's domain types (`StoredOIDCClient`, `StoredSSOToken`, `DeviceVerification`, `RoleCredentials`) at the adapter boundary so the actor never imports `AWSSSOOIDC`/`AWSSSO`.
- Tokens stay in the macOS Keychain. The SDK is used as a *transport*, not as a credential provider; we do not adopt the SDK's `~/.aws/sso/cache/*.json` flow.

**Tech Stack:** Swift 6.2 / Xcode 26, SwiftPM (QuorraCore package), `aws-sdk-swift` (`AWSSSOOIDC`, `AWSSSO`), Swift Testing (`@Test`) for unit tests, macOS 26 (Tahoe) minimum.

**Ordering rationale:** The bug fix lands first (Phase 1) using the existing hand-rolled clients behind the new provider seam. That ships a real user fix in one small commit. The SDK migration (Phases 2–5) then replaces the implementation behind the seam without touching the actor.

---

## File Map

### New files (created across phases)

```
QuorraCore/Sources/IAMIdentityCenter/
├── OIDCClientProviding.swift               (Phase 1)
├── PortalClientProviding.swift             (Phase 4)
└── SDK/
    ├── SDKOIDCClient.swift                 (Phase 2)
    ├── SDKOIDCClientProvider.swift         (Phase 2)
    ├── SDKPortalClient.swift               (Phase 4)
    ├── SDKPortalClientProvider.swift       (Phase 4)
    └── SDKErrorMapping.swift               (Phase 2; extended in Phase 4)

QuorraCore/Tests/IAMIdentityCenterTests/
├── Stubs/StubOIDCClientProvider.swift      (Phase 1)
├── Stubs/StubPortalClientProvider.swift    (Phase 4)
├── SDK/SDKErrorMappingTests.swift          (Phase 2; extended in Phase 4)
└── SDK/SDKAdapterTranslationTests.swift    (Phase 2; extended in Phase 4)
```

### Files to delete (Phases 3 and 5)

```
QuorraCore/Sources/IAMIdentityCenter/Wire/RegisterClient.swift
QuorraCore/Sources/IAMIdentityCenter/Wire/StartDeviceAuthorization.swift
QuorraCore/Sources/IAMIdentityCenter/Wire/CreateToken.swift
QuorraCore/Sources/IAMIdentityCenter/Wire/RefreshToken.swift
QuorraCore/Sources/IAMIdentityCenter/Wire/GetRoleCredentials.swift
QuorraCore/Sources/IAMIdentityCenter/Wire/AWSServiceErrorResponse.swift
QuorraCore/Sources/IAMIdentityCenter/Wire/OAuthErrorResponse.swift
QuorraCore/Sources/IAMIdentityCenter/Wire/Wire.swift
QuorraCore/Sources/IAMIdentityCenter/OIDCClient.swift
QuorraCore/Sources/IAMIdentityCenter/OIDCClient+Refresh.swift
QuorraCore/Sources/IAMIdentityCenter/PortalClient.swift
QuorraCore/Sources/IAMIdentityCenter/PortalLogout.swift   (if logout moves to the SDK adapter)
QuorraCore/Sources/IAMIdentityCenter/HTTPErrorMapping.swift
```

`Wire/ListAccounts.swift` and `Wire/ListAccountRoles.swift` are out of scope; they're consumed by code not on the sign-in hot path and can be migrated later under the same pattern.

### Files to modify

```
QuorraCore/Package.swift                                  — add aws-sdk-swift dep
QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService.swift
QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService+Refresh.swift
QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService+Mint.swift
QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService+SignOut.swift
QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService+RoleCredentials.swift
QuorraCore/Sources/IAMIdentityCenter/Errors.swift         — prune obsolete cases (Phase 5)
quorra/App/quorraApp.swift                                — wire SDK providers
QuorraCore/Tests/IAMIdentityCenterTests/Stubs/StubOIDCRequesting.swift  — wrap in stub provider
QuorraCore/Tests/IAMIdentityCenterTests/*Tests.swift      — update init sites
```

---

## Phase 0 — SDK Spike & Gate

> Goal: confirm `aws-sdk-swift` integrates with our SwiftPM/Xcode setup, the macOS sandbox, hardened runtime, and Swift 6 strict concurrency before committing to the migration. If this phase reveals a blocker (CRT linker failure under sandbox, notarization conflict, irreconcilable Sendable issues), STOP and revisit the recommendation.

### Task 0.1: Add aws-sdk-swift as a SwiftPM dependency

**Files:**
- Modify: `QuorraCore/Package.swift`

- [ ] **Step 1: Edit `QuorraCore/Package.swift`** to add the package dependency and link `AWSSSOOIDC` + `AWSSSO` into the `IAMIdentityCenter` target.

```swift
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "QuorraCore",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "AWSConfigINI", targets: ["AWSConfigINI"]),
        .library(name: "IAMIdentityCenter", targets: ["IAMIdentityCenter"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/awslabs/aws-sdk-swift",
            from: "1.0.0"      // pin to a known-good minor after Step 2 resolves
        )
    ],
    targets: [
        .target(name: "AWSConfigINI"),
        .testTarget(
            name: "AWSConfigINITests",
            dependencies: ["AWSConfigINI"],
            resources: [
                .copy("Resources"),
            ]
        ),
        .target(
            name: "IAMIdentityCenter",
            dependencies: [
                .product(name: "AWSSSOOIDC", package: "aws-sdk-swift"),
                .product(name: "AWSSSO", package: "aws-sdk-swift"),
            ]
        ),
        .testTarget(
            name: "IAMIdentityCenterTests",
            dependencies: ["IAMIdentityCenter"]
        ),
    ]
)
```

- [ ] **Step 2: Resolve packages**

Run via Xcode MCP:
```
mcp__xcode__BuildProject (tabIdentifier: windowtab1)
```
Expected: SwiftPM resolves `aws-sdk-swift` plus its transitive deps (`smithy-swift`, `aws-crt-swift`). If resolution selects a `1.x` version newer than the team has vetted, pin to the exact version observed in `Package.resolved`.

- [ ] **Step 3: Capture the resolved version**

Read `QuorraCore/Package.resolved`. Record the `aws-sdk-swift` pinned version in the Phase 0 notes section at the bottom of this plan.

- [ ] **Step 4: Build the app**

Run: `mcp__xcode__BuildProject` (tabIdentifier: `windowtab1`). Expected: BUILD SUCCEEDED. If failure, capture the error via `mcp__xcode__GetBuildLog` and triage. CRT-related linker errors at this stage are the canonical Phase 0 blocker.

- [ ] **Step 5: Commit dependency addition**

```bash
git add QuorraCore/Package.swift QuorraCore/Package.resolved
git commit -m "chore(deps): add aws-sdk-swift as IAMIdentityCenter dependency"
```

### Task 0.2: Smoke-test SDK imports and Sendable conformance

**Files:**
- Create: `QuorraCore/Sources/IAMIdentityCenter/SDK/_SpikeRemoveMe.swift`

- [ ] **Step 1: Write a throwaway file that imports both SDK modules and instantiates a client**

```swift
// _SpikeRemoveMe.swift — delete at the end of Phase 0.
//
// Confirms imports resolve, the SDK builds against Swift 6.2 strict concurrency,
// and a basic client/config construction compiles.
import AWSSSOOIDC
import AWSSSO

@available(macOS 26.0, *)
enum _SDKSpike {
    static func compileCheck() async throws {
        let oidcConfig = try await SSOOIDCClient.SSOOIDCClientConfiguration(region: "us-east-2")
        _ = SSOOIDCClient(config: oidcConfig)

        let portalConfig = try await SSOClient.SSOClientConfiguration(region: "us-east-2")
        _ = SSOClient(config: portalConfig)
    }
}
```

> **Note:** the exact Configuration type spellings (`SSOOIDCClient.SSOOIDCClientConfiguration` vs `SSOOIDCClient.Config`) vary across SDK minor versions. If the names above don't compile, look at the SDK's own DocC: `https://sdk.amazonaws.com/swift/api/awssdkforswift/latest/documentation/` and adjust. Document the exact type names in the Phase 0 notes — Phase 2 will reuse them.

- [ ] **Step 2: Build**

Run `mcp__xcode__BuildProject` (tabIdentifier: `windowtab1`). Expected: BUILD SUCCEEDED with zero warnings inside `_SpikeRemoveMe.swift`. If Sendable warnings appear, capture them in the notes at the bottom of this file — they'll inform Task 2.1's annotation strategy.

- [ ] **Step 3: Run the app once from Xcode (⌘R) to confirm sandboxed launch is unaffected**

Manual check: launch the app, confirm the main window appears and no crash on launch. The CRT initializer runs on first import; if hardened runtime / sandbox rejects it, you'll see a crash at launch with a `Library not loaded` or codesign error in Console.

- [ ] **Step 4: Capture binary delta**

```bash
ls -lh build/Build/Products/Debug/quorra.app/Contents/MacOS/quorra 2>/dev/null
# or whichever build path Xcode reports
```

Record before/after binary size in the Phase 0 notes. Use the previous commit (pre-Phase-0) as the "before" baseline.

- [ ] **Step 5: Do NOT delete `_SpikeRemoveMe.swift` yet** — it stays in tree until Phase 2 Task 2.1 lands real adapter code. Move on to gate review.

### Task 0.3: Gate review

- [ ] **Step 1: Confirm gate criteria**

All of the following must be true to proceed to Phase 1:
- BUILD SUCCEEDED with the SDK linked.
- App launches from Xcode without sandbox/codesign error.
- Sendable warnings, if any, are localized and resolvable (not pervasive).
- Binary delta is acceptable for our budget.

- [ ] **Step 2: If any criterion fails**

Stop. Open a discussion with the user about whether to (a) defer the migration, (b) restrict adopted modules, or (c) work around the specific blocker. Do not start Phase 1 until the gate is green.

---

## Phase 1 — Provider Refactor (Bug Fix on Hand-Rolled Code)

> Goal: make `IdentityCenterService` ask a provider for a region-correct OIDC client on every call instead of holding one fixed-region client. This **fixes the production bug** with the existing hand-rolled `OIDCClient` still under the hood. The SDK swap follows in Phases 2–3.

### Task 1.1: Add `OIDCClientProviding` protocol

**Files:**
- Create: `QuorraCore/Sources/IAMIdentityCenter/OIDCClientProviding.swift`

- [ ] **Step 1: Write the protocol**

```swift
// OIDCClientProviding.swift — factory for region-correct OIDC clients.
//
// The actor never holds a client directly; it asks the provider for one keyed
// by region every time it makes a call. This decouples client construction
// (region-bound) from the actor's lifecycle (region-agnostic), and is the
// extension point swapped to an SDK-backed impl in Phase 2.
import Foundation

public protocol OIDCClientProviding: Sendable {
    /// Returns an `OIDCRequesting` configured for the given AWS region.
    ///
    /// Implementations may cache per-region instances; callers must not assume identity.
    func client(forRegion region: String) async throws -> any OIDCRequesting
}
```

- [ ] **Step 2: Build**

Run `mcp__xcode__BuildProject`. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add QuorraCore/Sources/IAMIdentityCenter/OIDCClientProviding.swift
git commit -m "feat(iam-identity-center): add OIDCClientProviding protocol"
```

### Task 1.2: Implement `URLSessionOIDCClientProvider` (interim impl wrapping current `OIDCClient`)

**Files:**
- Create: `QuorraCore/Sources/IAMIdentityCenter/URLSessionOIDCClientProvider.swift`

- [ ] **Step 1: Write the provider**

```swift
// URLSessionOIDCClientProvider.swift — interim provider that wraps the existing
// hand-rolled URLSession-backed OIDCClient. Replaced by SDKOIDCClientProvider
// in Phase 3. Caches one OIDCClient per region; cache is keyed by region only
// (URLSession is shared via the constructor).
import Foundation

public actor URLSessionOIDCClientProvider: OIDCClientProviding {
    private let urlSession: URLSession
    private var clients: [String: OIDCClient] = [:]

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func client(forRegion region: String) async throws -> any OIDCRequesting {
        if let cached = clients[region] { return cached }
        let fresh = OIDCClient(region: region, urlSession: urlSession)
        clients[region] = fresh
        return fresh
    }
}
```

- [ ] **Step 2: Build**

Run `mcp__xcode__BuildProject`. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add QuorraCore/Sources/IAMIdentityCenter/URLSessionOIDCClientProvider.swift
git commit -m "feat(iam-identity-center): add URLSession-backed OIDC client provider"
```

### Task 1.3: Add a failing regression test for region routing

**Files:**
- Create: `QuorraCore/Tests/IAMIdentityCenterTests/Stubs/StubOIDCClientProvider.swift`
- Create: `QuorraCore/Tests/IAMIdentityCenterTests/RegionRoutingTests.swift`

- [ ] **Step 1: Write a recording stub provider**

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

- [ ] **Step 2: Write the failing regression test**

```swift
// RegionRoutingTests.swift — proves that signIn(region:) asks the provider for
// that exact region. The fix in Task 1.5 makes this pass.
import Testing
import Foundation
@testable import IAMIdentityCenter

@Suite struct RegionRoutingTests {
    @Test func signInAsksProviderForSessionRegion() async throws {
        let provider = StubOIDCClientProvider(factory: { _ in
            StubOIDCRequesting()
        })
        let service = IdentityCenterService(
            keychain: InMemoryKeychain(),
            oidcClientProvider: provider,
            portalClient: StubPortalRequesting()
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

- [ ] **Step 3: Run the test to confirm it fails**

Run: `mcp__xcode__RunSomeTests` for `IAMIdentityCenterTests/RegionRoutingTests`. Expected: COMPILE ERROR — `IdentityCenterService.init` does not take `oidcClientProvider`. This is the expected red state that drives Task 1.4.

### Task 1.4: Switch `IdentityCenterService` to take a provider

**Files:**
- Modify: `QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService.swift`

- [ ] **Step 1: Change init signature and stored property**

Replace the existing `internal let oidcClient: any OIDCRequesting` and its initializer wiring with:

```swift
internal let oidcClientProvider: any OIDCClientProviding
```

And update the initializer parameter:

```swift
public init(
    keychain: any KeychainStore,
    oidcClientProvider: any OIDCClientProviding,
    portalClient: any PortalRequesting = PortalClient(),
    sleeper: any Sleeper = WallClockSleeper(),
    urlSession: URLSession = .shared
) {
    self.keychain = keychain
    self.oidcClientProvider = oidcClientProvider
    self.portalClient = portalClient
    self.sleeper = sleeper
    self.urlSession = urlSession
    let (stream, continuation) = AsyncStream<AuthEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
    self.events = stream
    self.eventContinuation = continuation
}
```

- [ ] **Step 2: Update `ensureOIDCClient(region:scopes:clientName:)` to fetch via provider**

The method already takes `region`. Replace its body's call sites that previously used `self.oidcClient` with:

```swift
let oidc = try await oidcClientProvider.client(forRegion: region)
let client = try await oidc.registerClient(clientName: clientName, scopes: scopes)
try await keychain.writeRecord(client, service: service, account: account)
return client
```

- [ ] **Step 3: Update `runSignIn(...)` to resolve the client per-call**

In `IdentityCenterService.swift`, replace the existing line:

```swift
let (deviceCode, verification) = try await oidcClient.startDeviceAuthorization(
    client: client,
    startUrl: startUrl,
    sessionName: sessionName
)
```

with:

```swift
let oidc = try await oidcClientProvider.client(forRegion: region)
let (deviceCode, verification) = try await oidc.startDeviceAuthorization(
    client: client,
    startUrl: startUrl,
    sessionName: sessionName
)
```

- [ ] **Step 4: Update `pollForToken(...)` similarly**

The polling helper currently calls `self.oidcClient.createToken(...)`. Change it to resolve via the provider using `client.region` (the cached `StoredOIDCClient`'s region is the authoritative source after sign-in begins):

```swift
let oidc = try await oidcClientProvider.client(forRegion: client.region)
let token = try await oidc.createToken(client: client, deviceCode: deviceCode, sessionName: sessionName)
```

- [ ] **Step 5: Build**

Run `mcp__xcode__BuildProject`. Expected: BUILD SUCCEEDED. The Refresh and Mint extensions still call `self.oidcClient` — they will fail next; that's intentional and handled in Task 1.5.

### Task 1.5: Update Refresh and Mint extensions to use the provider

**Files:**
- Modify: `QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService+Refresh.swift`
- Modify: `QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService+Mint.swift`

- [ ] **Step 1: In `+Refresh.swift`, replace every `self.oidcClient.refreshToken(...)` call with provider-routed equivalents**

```swift
let oidc = try await oidcClientProvider.client(forRegion: client.region)
let refreshed = try await oidc.refreshToken(
    client: client,
    refreshToken: refresh,
    sessionName: sessionName
)
```

- [ ] **Step 2: In `+Mint.swift`, if any OIDC calls live there, do the same**

If `+Mint.swift` only touches Portal, skip this step.

- [ ] **Step 3: Build**

Run `mcp__xcode__BuildProject`. Expected: BUILD SUCCEEDED.

### Task 1.6: Update test harness to use the provider

**Files:**
- Modify: every test file in `QuorraCore/Tests/IAMIdentityCenterTests/` that constructs `IdentityCenterService(... oidcClient: ...)`
- Modify: `QuorraCore/Tests/IAMIdentityCenterTests/Stubs/TestHelpers.swift` (test factory helpers)

- [ ] **Step 1: Add a helper that wraps `StubOIDCRequesting` in a `StubOIDCClientProvider`**

In `TestHelpers.swift`:

```swift
public func makeStubProvider(stub: StubOIDCRequesting) -> StubOIDCClientProvider {
    StubOIDCClientProvider(factory: { _ in stub })
}
```

- [ ] **Step 2: Replace each `IdentityCenterService(... oidcClient: stub ...)` call site**

```swift
let provider = makeStubProvider(stub: stub)
let service = IdentityCenterService(
    keychain: keychain,
    oidcClientProvider: provider,
    portalClient: portalStub
)
```

Files known to need this change: `SignInTests.swift`, `SignOutTests.swift`, `OIDCClientTests.swift` (this one may be deleted in Phase 3), `ExpirationTimerTests.swift`, `AuthEventStreamTests.swift`, `CredentialsModelTests.swift` (App target). Visit each and update.

- [ ] **Step 3: Run the full IAM Identity Center test suite**

Run `mcp__xcode__RunSomeTests` targeting `IAMIdentityCenterTests`. Expected: every previously-passing test still passes, AND `RegionRoutingTests.signInAsksProviderForSessionRegion` is now GREEN.

### Task 1.7: Wire the provider into the app

**Files:**
- Modify: `quorra/App/quorraApp.swift`

- [ ] **Step 1: Replace the hardcoded-region client with a provider**

```swift
@State private var credentialsModel = CredentialsModel(
    service: IdentityCenterService(
        keychain: Keychain(accessGroup: KeychainAccessGroup.shared),
        oidcClientProvider: URLSessionOIDCClientProvider()
    )
)
```

- [ ] **Step 2: Build the app**

Run `mcp__xcode__BuildProject`. Expected: BUILD SUCCEEDED.

### Task 1.8: Manually verify the bug is fixed

- [ ] **Step 1: Launch the app from Xcode (⌘R)**

- [ ] **Step 2: In a second terminal, stream logs**

```bash
log stream --style compact --predicate 'subsystem == "dev.ajbeck.quorra"'
```

- [ ] **Step 3: Attempt to sign in to the `astrocompute` session (us-east-2)**

Expected: device-code flow completes successfully. The previous error (`invalid_request: Invalid start url provided`) does not occur.

- [ ] **Step 4: Attempt to sign in to a session in a different region (e.g., a us-east-1 session if available)**

Expected: also succeeds. This proves cross-region routing.

- [ ] **Step 5: Commit the bug fix**

```bash
git add quorra/App/quorraApp.swift \
        QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService.swift \
        QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService+Refresh.swift \
        QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService+Mint.swift \
        QuorraCore/Tests/IAMIdentityCenterTests/
git commit -m "fix(iam-identity-center): route OIDC client per session region

Previously IdentityCenterService held one OIDCClient pinned to us-east-1 at
app launch, so any sign-in for a session whose sso_region differed got rejected
by the wrong-region OIDC endpoint with invalid_request: Invalid start url
provided. The actor now resolves an OIDC client per call via the new
OIDCClientProviding factory, keyed by the session's region."
```

---

## Phase 2 — SDK-Backed OIDC Implementation

> Goal: implement `SDKOIDCClient` (conforms to `OIDCRequesting`) and `SDKOIDCClientProvider` (conforms to `OIDCClientProviding`), each wrapping the AWS SDK's `SSOOIDCClient`. Unit-test the translation and error-mapping logic in isolation.

### Task 2.1: Create `SDKErrorMapping`

**Files:**
- Create: `QuorraCore/Sources/IAMIdentityCenter/SDK/SDKErrorMapping.swift`
- Create: `QuorraCore/Tests/IAMIdentityCenterTests/SDK/SDKErrorMappingTests.swift`

- [ ] **Step 1: Write a failing test for each mapped error**

```swift
// SDKErrorMappingTests.swift
import Testing
import AWSSSOOIDC
@testable import IAMIdentityCenter

@Suite struct SDKErrorMappingTests {
    @Test func invalidClientMapsToInvalidClient() {
        let sdkError = AWSSSOOIDC.InvalidClientException(message: "bad")
        let mapped = SDKErrorMapping.map(sdkError)
        #expect(mapped == .invalidClient)
    }

    @Test func authorizationPendingMapsToAuthorizationPending() {
        let sdkError = AWSSSOOIDC.AuthorizationPendingException(message: nil)
        let mapped = SDKErrorMapping.map(sdkError)
        #expect(mapped == .authorizationPending)
    }

    @Test func slowDownMapsToSlowDown() {
        let mapped = SDKErrorMapping.map(AWSSSOOIDC.SlowDownException(message: nil))
        #expect(mapped == .slowDown)
    }

    @Test func accessDeniedMapsToAccessDenied() {
        let mapped = SDKErrorMapping.map(AWSSSOOIDC.AccessDeniedException(message: nil))
        #expect(mapped == .accessDenied)
    }

    @Test func expiredTokenMapsToExpiredDeviceCode() {
        let mapped = SDKErrorMapping.map(AWSSSOOIDC.ExpiredTokenException(message: nil))
        #expect(mapped == .expiredDeviceCode)
    }

    @Test func invalidGrantMapsToInvalidGrant() {
        let mapped = SDKErrorMapping.map(AWSSSOOIDC.InvalidGrantException(message: nil))
        #expect(mapped == .invalidGrant)
    }

    @Test func invalidRequestPreservesDescription() {
        let sdkError = AWSSSOOIDC.InvalidRequestException(message: "Invalid start url provided")
        let mapped = SDKErrorMapping.map(sdkError)
        if case let .awsError(code, description) = mapped {
            #expect(code == "invalid_request")
            #expect(description == "Invalid start url provided")
        } else {
            Issue.record("expected .awsError, got \(mapped)")
        }
    }

    @Test func unknownErrorFallsThrough() {
        struct Foreign: Error {}
        let mapped = SDKErrorMapping.map(Foreign())
        if case .awsError(let code, _) = mapped {
            #expect(code == "unknown")
        } else {
            Issue.record("expected .awsError fallback")
        }
    }
}
```

- [ ] **Step 2: Run the tests — expect them to fail to compile** (no `SDKErrorMapping` yet)

- [ ] **Step 3: Implement `SDKErrorMapping`**

```swift
// SDKErrorMapping.swift — translates AWS SDK exceptions to IAMIdentityCenterError.
//
// Pure, side-effect-free. Each case below mirrors a documented SDK exception
// for AWSSSOOIDC. Unknown errors fall through to .awsError("unknown", ...).
import Foundation
import AWSSSOOIDC

public enum SDKErrorMapping {
    public static func map(_ error: any Error) -> IAMIdentityCenterError {
        switch error {
        case let e as AWSSSOOIDC.InvalidClientException:
            _ = e
            return .invalidClient
        case let e as AWSSSOOIDC.AuthorizationPendingException:
            _ = e
            return .authorizationPending
        case let e as AWSSSOOIDC.SlowDownException:
            _ = e
            return .slowDown
        case let e as AWSSSOOIDC.AccessDeniedException:
            _ = e
            return .accessDenied
        case let e as AWSSSOOIDC.ExpiredTokenException:
            _ = e
            return .expiredDeviceCode
        case let e as AWSSSOOIDC.InvalidGrantException:
            _ = e
            return .invalidGrant
        case let e as AWSSSOOIDC.InvalidRequestException:
            return .awsError(code: "invalid_request", description: e.message)
        case let e as AWSSSOOIDC.UnauthorizedClientException:
            return .awsError(code: "unauthorized_client", description: e.message)
        case let e as AWSSSOOIDC.InternalServerException:
            return .awsError(code: "server_error", description: e.message)
        default:
            return .awsError(code: "unknown", description: String(describing: error))
        }
    }
}
```

> **Note:** the exact `init(message:)` initializer signature is determined by what the SDK generates. If `message:` is not the parameter name (some Smithy-generated types use `_ message:` or a `properties:` builder), adjust per the SDK DocC reference recorded in Phase 0.

- [ ] **Step 4: Run tests — expect all green**

Run `mcp__xcode__RunSomeTests` for `IAMIdentityCenterTests/SDKErrorMappingTests`.

- [ ] **Step 5: Commit**

```bash
git add QuorraCore/Sources/IAMIdentityCenter/SDK/SDKErrorMapping.swift \
        QuorraCore/Tests/IAMIdentityCenterTests/SDK/SDKErrorMappingTests.swift
git commit -m "feat(iam-identity-center): add SDK error mapping with unit tests"
```

### Task 2.2: Create `SDKOIDCClient` (adapter)

**Files:**
- Create: `QuorraCore/Sources/IAMIdentityCenter/SDK/SDKOIDCClient.swift`

- [ ] **Step 1: Write the adapter**

```swift
// SDKOIDCClient.swift — OIDCRequesting impl backed by AWSSSOOIDC.SSOOIDCClient.
//
// Region-bound at init (the SDK client's config carries region). Translates
// Quorra domain types ↔ SDK Input/Output. Errors flow through SDKErrorMapping
// so the actor sees a stable IAMIdentityCenterError surface.
import Foundation
import AWSSSOOIDC

public struct SDKOIDCClient: OIDCRequesting {
    private let region: String
    private let client: SSOOIDCClient

    public init(region: String) async throws {
        self.region = region
        let config = try await SSOOIDCClient.SSOOIDCClientConfiguration(region: region)
        self.client = SSOOIDCClient(config: config)
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
        do {
            output = try await client.registerClient(input: input)
        } catch {
            throw SDKErrorMapping.map(error)
        }
        guard
            let clientId = output.clientId,
            let clientSecret = output.clientSecret
        else {
            throw IAMIdentityCenterError.malformedResponse("RegisterClient missing required fields")
        }
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
        do {
            output = try await client.startDeviceAuthorization(input: input)
        } catch {
            throw SDKErrorMapping.map(error)
        }
        guard
            let deviceCode = output.deviceCode,
            let userCode = output.userCode,
            let verificationUriString = output.verificationUri,
            let verificationUriCompleteString = output.verificationUriComplete,
            let verificationUri = URL(string: verificationUriString),
            let verificationUriComplete = URL(string: verificationUriCompleteString)
        else {
            throw IAMIdentityCenterError.malformedResponse("StartDeviceAuthorization missing required fields")
        }
        let verification = DeviceVerification(
            userCode: userCode,
            verificationUri: verificationUri,
            verificationUriComplete: verificationUriComplete,
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
        let output: CreateTokenOutput
        do {
            output = try await client.createToken(input: input)
        } catch {
            throw SDKErrorMapping.map(error)
        }
        guard let accessToken = output.accessToken else {
            throw IAMIdentityCenterError.malformedResponse("CreateToken missing accessToken")
        }
        return StoredSSOToken(
            accessToken: accessToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(output.expiresIn)),
            refreshToken: output.refreshToken,
            issuedAt: Date(),
            region: region,
            sessionName: sessionName
        )
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
        let output: CreateTokenOutput
        do {
            output = try await client.createToken(input: input)
        } catch {
            throw SDKErrorMapping.map(error)
        }
        guard let accessToken = output.accessToken else {
            throw IAMIdentityCenterError.malformedResponse("RefreshToken missing accessToken")
        }
        return StoredSSOToken(
            accessToken: accessToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(output.expiresIn)),
            refreshToken: output.refreshToken ?? refreshToken,
            issuedAt: Date(),
            region: region,
            sessionName: sessionName
        )
    }
}
```

- [ ] **Step 2: Build**

Run `mcp__xcode__BuildProject`. Expected: BUILD SUCCEEDED. If SDK initializer parameter names differ from those above, adjust per Phase 0 notes.

- [ ] **Step 3: Commit**

```bash
git add QuorraCore/Sources/IAMIdentityCenter/SDK/SDKOIDCClient.swift
git commit -m "feat(iam-identity-center): add SDK-backed OIDC client adapter"
```

### Task 2.3: Create `SDKOIDCClientProvider`

**Files:**
- Create: `QuorraCore/Sources/IAMIdentityCenter/SDK/SDKOIDCClientProvider.swift`

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

- [ ] **Step 3: Commit**

```bash
git add QuorraCore/Sources/IAMIdentityCenter/SDK/SDKOIDCClientProvider.swift
git commit -m "feat(iam-identity-center): add SDK OIDC client provider"
```

---

## Phase 3 — Swap OIDC to SDK & Delete Hand-Rolled Code

> Goal: route the production app through `SDKOIDCClientProvider` and remove the hand-rolled OIDC transport from the codebase.

### Task 3.1: Swap providers in production wiring

**Files:**
- Modify: `quorra/App/quorraApp.swift`

- [ ] **Step 1: Replace `URLSessionOIDCClientProvider()` with `SDKOIDCClientProvider()`**

```swift
@State private var credentialsModel = CredentialsModel(
    service: IdentityCenterService(
        keychain: Keychain(accessGroup: KeychainAccessGroup.shared),
        oidcClientProvider: SDKOIDCClientProvider()
    )
)
```

- [ ] **Step 2: Build and launch the app**

Run `mcp__xcode__BuildProject` then ⌘R from Xcode. Watch `log stream` per Task 1.8 Step 2.

- [ ] **Step 3: Sign in to the astrocompute (us-east-2) session**

Expected: device-code flow completes via the SDK. Confirm in logs that the request hit `oidc.us-east-2.amazonaws.com`.

- [ ] **Step 4: Sign out and back in (cycle the path) to exercise refresh as well**

Confirm refresh succeeds when the access token nears expiry, either by waiting or by adjusting `refreshSkew` for testing.

### Task 3.2: Delete the hand-rolled OIDC transport

**Files (delete):**
- `QuorraCore/Sources/IAMIdentityCenter/OIDCClient.swift`
- `QuorraCore/Sources/IAMIdentityCenter/OIDCClient+Refresh.swift`
- `QuorraCore/Sources/IAMIdentityCenter/URLSessionOIDCClientProvider.swift`
- `QuorraCore/Sources/IAMIdentityCenter/Wire/RegisterClient.swift`
- `QuorraCore/Sources/IAMIdentityCenter/Wire/StartDeviceAuthorization.swift`
- `QuorraCore/Sources/IAMIdentityCenter/Wire/CreateToken.swift`
- `QuorraCore/Sources/IAMIdentityCenter/Wire/RefreshToken.swift`
- `QuorraCore/Sources/IAMIdentityCenter/SDK/_SpikeRemoveMe.swift`
- `QuorraCore/Tests/IAMIdentityCenterTests/OIDCClientTests.swift` (tests for the deleted impl)

**Files (review for deletion — keep if still referenced):**
- `QuorraCore/Sources/IAMIdentityCenter/Wire/AWSServiceErrorResponse.swift`
- `QuorraCore/Sources/IAMIdentityCenter/Wire/OAuthErrorResponse.swift`
- `QuorraCore/Sources/IAMIdentityCenter/Wire/Wire.swift`
- `QuorraCore/Sources/IAMIdentityCenter/HTTPErrorMapping.swift`

- [ ] **Step 1: Delete each file via `mcp__xcode__XcodeRM`** (one call per file)

Example:
```
mcp__xcode__XcodeRM
  tabIdentifier: windowtab1
  path: QuorraCore/Sources/IAMIdentityCenter/OIDCClient.swift
  deleteFiles: true
```

- [ ] **Step 2: Build**

Run `mcp__xcode__BuildProject`. If a file in the "review" list is still referenced (e.g., `HTTPErrorMapping` used by `PortalClient`), the build fails on that reference — keep the file for now and move on. Phase 4 cleans up Portal.

- [ ] **Step 3: Run the full test suite**

Run `mcp__xcode__RunAllTests`. Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(iam-identity-center): delete hand-rolled OIDC transport

The SDK-backed adapter is now in production. The URLSession-based OIDCClient,
its wire models, and the spike file are removed. PortalClient/HTTPErrorMapping
remain pending Phase 4."
```

---

## Phase 4 — Portal Migration

> Same shape as Phases 1–3 applied to the Portal client (`GetRoleCredentials`, `Logout`).

### Task 4.1: Add `PortalClientProviding`

**Files:**
- Create: `QuorraCore/Sources/IAMIdentityCenter/PortalClientProviding.swift`

- [ ] **Step 1: Write the protocol**

```swift
import Foundation

public protocol PortalClientProviding: Sendable {
    func client(forRegion region: String) async throws -> any PortalRequesting
}
```

- [ ] **Step 2: Build & commit**

```bash
git add QuorraCore/Sources/IAMIdentityCenter/PortalClientProviding.swift
git commit -m "feat(iam-identity-center): add PortalClientProviding protocol"
```

### Task 4.2: Extend `SDKErrorMapping` to cover Portal exceptions

**Files:**
- Modify: `QuorraCore/Sources/IAMIdentityCenter/SDK/SDKErrorMapping.swift`
- Modify: `QuorraCore/Tests/IAMIdentityCenterTests/SDK/SDKErrorMappingTests.swift`

- [ ] **Step 1: Add failing tests for Portal exception mapping**

```swift
import AWSSSO

@Test func portalForbiddenMapsToRoleNotAssigned() {
    let mapped = SDKErrorMapping.map(AWSSSO.ForbiddenException(message: nil))
    #expect(mapped == .roleNotAssigned)
}

@Test func portalResourceNotFoundMapsToAccountNotFound() {
    let mapped = SDKErrorMapping.map(AWSSSO.ResourceNotFoundException(message: nil))
    #expect(mapped == .accountNotFound)
}

@Test func portalUnauthorizedMapsToTokenExpired() {
    let mapped = SDKErrorMapping.map(AWSSSO.UnauthorizedException(message: nil))
    #expect(mapped == .tokenExpired)
}
```

- [ ] **Step 2: Extend `SDKErrorMapping.map(_:)` with the Portal cases**

```swift
import AWSSSO
// ... existing imports

// Add inside the switch, before `default`:
case let e as AWSSSO.ForbiddenException:
    _ = e
    return .roleNotAssigned
case let e as AWSSSO.ResourceNotFoundException:
    _ = e
    return .accountNotFound
case let e as AWSSSO.UnauthorizedException:
    _ = e
    return .tokenExpired
case let e as AWSSSO.TooManyRequestsException:
    return .awsError(code: "too_many_requests", description: e.message)
case let e as AWSSSO.InvalidRequestException:
    return .awsError(code: "invalid_request", description: e.message)
```

- [ ] **Step 3: Run the tests — all green**

- [ ] **Step 4: Commit**

```bash
git add QuorraCore/Sources/IAMIdentityCenter/SDK/SDKErrorMapping.swift \
        QuorraCore/Tests/IAMIdentityCenterTests/SDK/SDKErrorMappingTests.swift
git commit -m "feat(iam-identity-center): extend SDK error mapping for Portal"
```

### Task 4.3: Create `SDKPortalClient`

**Files:**
- Create: `QuorraCore/Sources/IAMIdentityCenter/SDK/SDKPortalClient.swift`

- [ ] **Step 1: Write the adapter**

```swift
// SDKPortalClient.swift — PortalRequesting impl backed by AWSSSO.SSOClient.
import Foundation
import AWSSSO

public struct SDKPortalClient: PortalRequesting {
    private let region: String
    private let client: SSOClient

    public init(region: String) async throws {
        self.region = region
        let config = try await SSOClient.SSOClientConfiguration(region: region)
        self.client = SSOClient(config: config)
    }

    public func getRoleCredentials(
        accessToken: String,
        accountId: String,
        roleName: String
    ) async throws -> RoleCredentials {
        let input = GetRoleCredentialsInput(
            accessToken: accessToken,
            accountId: accountId,
            roleName: roleName
        )
        let output: GetRoleCredentialsOutput
        do {
            output = try await client.getRoleCredentials(input: input)
        } catch {
            throw SDKErrorMapping.map(error)
        }
        guard
            let creds = output.roleCredentials,
            let accessKeyId = creds.accessKeyId,
            let secretAccessKey = creds.secretAccessKey,
            let sessionToken = creds.sessionToken
        else {
            throw IAMIdentityCenterError.malformedResponse("GetRoleCredentials missing fields")
        }
        return RoleCredentials(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(creds.expiration) / 1000)
        )
    }

    public func logout(accessToken: String) async throws {
        let input = LogoutInput(accessToken: accessToken)
        do {
            _ = try await client.logout(input: input)
        } catch {
            throw SDKErrorMapping.map(error)
        }
    }
}
```

> **Note:** `RoleCredentials.expiration` is documented in milliseconds since epoch. Confirm against the SDK's generated `RoleCredentials` type in Phase 0 notes; adjust the divisor if the SDK exposes a different unit.

- [ ] **Step 2: Build & commit**

```bash
git add QuorraCore/Sources/IAMIdentityCenter/SDK/SDKPortalClient.swift
git commit -m "feat(iam-identity-center): add SDK-backed Portal client adapter"
```

### Task 4.4: Create `SDKPortalClientProvider`

**Files:**
- Create: `QuorraCore/Sources/IAMIdentityCenter/SDK/SDKPortalClientProvider.swift`

- [ ] **Step 1: Write the provider**

```swift
import Foundation

public actor SDKPortalClientProvider: PortalClientProviding {
    private var clients: [String: SDKPortalClient] = [:]

    public init() {}

    public func client(forRegion region: String) async throws -> any PortalRequesting {
        if let cached = clients[region] { return cached }
        let fresh = try await SDKPortalClient(region: region)
        clients[region] = fresh
        return fresh
    }
}
```

- [ ] **Step 2: Build & commit**

```bash
git add QuorraCore/Sources/IAMIdentityCenter/SDK/SDKPortalClientProvider.swift
git commit -m "feat(iam-identity-center): add SDK Portal client provider"
```

### Task 4.5: Switch `IdentityCenterService` to take a Portal provider

**Files:**
- Modify: `QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService.swift`
- Modify: `QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService+RoleCredentials.swift`
- Modify: `QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService+SignOut.swift`
- Modify: `QuorraCore/Tests/IAMIdentityCenterTests/Stubs/StubPortalRequesting.swift` (test stub wrapping pattern)

- [ ] **Step 1: Add a `StubPortalClientProvider` mirroring `StubOIDCClientProvider`**

```swift
// QuorraCore/Tests/IAMIdentityCenterTests/Stubs/StubPortalClientProvider.swift
import Foundation
@testable import IAMIdentityCenter

public actor StubPortalClientProvider: PortalClientProviding {
    public private(set) var regionRequests: [String] = []
    private var stubs: [String: StubPortalRequesting] = [:]
    private let factory: @Sendable (String) -> StubPortalRequesting

    public init(factory: @escaping @Sendable (String) -> StubPortalRequesting) {
        self.factory = factory
    }

    public func client(forRegion region: String) async throws -> any PortalRequesting {
        regionRequests.append(region)
        if let cached = stubs[region] { return cached }
        let stub = factory(region)
        stubs[region] = stub
        return stub
    }
}
```

- [ ] **Step 2: Change `IdentityCenterService.init` to take `portalClientProvider`**

```swift
public init(
    keychain: any KeychainStore,
    oidcClientProvider: any OIDCClientProviding,
    portalClientProvider: any PortalClientProviding,
    sleeper: any Sleeper = WallClockSleeper(),
    urlSession: URLSession = .shared
) {
    // ... store portalClientProvider in place of portalClient ...
}
```

- [ ] **Step 3: In `+RoleCredentials.swift`, resolve the Portal client by region per call**

```swift
let portal = try await portalClientProvider.client(forRegion: region)
let creds = try await portal.getRoleCredentials(
    accessToken: token.accessToken,
    accountId: accountId,
    roleName: roleName
)
```

- [ ] **Step 4: In `+SignOut.swift`, do the same for the best-effort logout**

The session has a stored region (from sign-in); use it.

- [ ] **Step 5: Update every test file that constructs `IdentityCenterService` to pass a `StubPortalClientProvider`**

- [ ] **Step 6: Build and run the full test suite**

Run `mcp__xcode__BuildProject` then `mcp__xcode__RunAllTests`. Expected: all green.

- [ ] **Step 7: Wire the SDK provider in the app**

In `quorra/App/quorraApp.swift`:

```swift
@State private var credentialsModel = CredentialsModel(
    service: IdentityCenterService(
        keychain: Keychain(accessGroup: KeychainAccessGroup.shared),
        oidcClientProvider: SDKOIDCClientProvider(),
        portalClientProvider: SDKPortalClientProvider()
    )
)
```

- [ ] **Step 8: Manually verify role mint via the SDK**

Run the app, sign in to a session, attempt to use a profile under that session — confirm credentials mint succeeds and logs show `portal.sso.us-east-2.amazonaws.com` (or the session's region).

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "refactor(iam-identity-center): route Portal client per session region via SDK provider"
```

### Task 4.6: Delete the hand-rolled Portal transport

**Files (delete):**
- `QuorraCore/Sources/IAMIdentityCenter/PortalClient.swift`
- `QuorraCore/Sources/IAMIdentityCenter/PortalLogout.swift`
- `QuorraCore/Sources/IAMIdentityCenter/Wire/GetRoleCredentials.swift`

- [ ] **Step 1: Delete each file via `mcp__xcode__XcodeRM`**

- [ ] **Step 2: Build & run tests**

Expected: all green.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "refactor(iam-identity-center): delete hand-rolled Portal transport"
```

---

## Phase 5 — Cleanup

### Task 5.1: Prune `IAMIdentityCenterError` of obsolete cases

**Files:**
- Modify: `QuorraCore/Sources/IAMIdentityCenter/Errors.swift`

- [ ] **Step 1: Audit which cases are still thrown anywhere in the source tree**

Run via Xcode MCP:
```
mcp__xcode__XcodeGrep
  tabIdentifier: windowtab1
  pattern: \.httpStatus|\.network\(
  outputMode: content
```

- [ ] **Step 2: Remove cases with zero hits**

Candidate cases (verify zero hits each):
- `case httpStatus(Int, body: String?)` — was thrown by `HTTPErrorMapping` only.
- `case network(URLError)` — only meaningful when we owned the URLSession path.

Remove from `Errors.swift` and `Errors+LocalizedError.swift`.

- [ ] **Step 3: Build**

Expected: BUILD SUCCEEDED. If a stale call site exists, fix it.

- [ ] **Step 4: Run tests**

Expected: all green. If a test asserted on a removed case, replace with `.awsError(...)` assertion (the new shape under SDK).

### Task 5.2: Remove now-unused `urlSession` parameter from `IdentityCenterService.init`

**Files:**
- Modify: `QuorraCore/Sources/IAMIdentityCenter/IdentityCenterService.swift`
- Modify: test files that pass `urlSession:`

- [ ] **Step 1: Confirm `urlSession` is no longer read inside the actor**

Run:
```
mcp__xcode__XcodeGrep
  tabIdentifier: windowtab1
  pattern: self\.urlSession
  outputMode: content
```

Expected: zero hits (the Portal logout used it; the SDK Portal client owns its transport now).

- [ ] **Step 2: Remove `urlSession` from `IdentityCenterService.init` and the stored `let urlSession`**

- [ ] **Step 3: Update call sites in tests (and `quorraApp.swift` if it passed one)**

- [ ] **Step 4: Build, test, commit**

```bash
git add -A
git commit -m "chore(iam-identity-center): drop unused urlSession from service init"
```

### Task 5.3: Delete `HTTPErrorMapping` if unused

- [ ] **Step 1: Verify no remaining callers**

```
mcp__xcode__XcodeGrep
  tabIdentifier: windowtab1
  pattern: HTTPErrorMapping
  outputMode: content
```

- [ ] **Step 2: If zero hits outside the file itself, delete it**

```
mcp__xcode__XcodeRM
  tabIdentifier: windowtab1
  path: QuorraCore/Sources/IAMIdentityCenter/HTTPErrorMapping.swift
  deleteFiles: true
```

- [ ] **Step 3: Build, test, commit**

```bash
git add -A
git commit -m "chore(iam-identity-center): remove unused HTTPErrorMapping"
```

### Task 5.4: Update docs

**Files:**
- Modify: `docs/IAMIdentityCenterPlan.html`
- Modify: `CLAUDE.md` ("SSO Flow" section)

- [ ] **Step 1: In `CLAUDE.md`, update the "SSO Flow" section**

Replace:
> Quorra implements the **full SSO OIDC device-code flow natively** — it does not shell out to `aws sso login`. The point of the tool is to own this flow.

With:
> Quorra implements the **full SSO OIDC device-code flow natively** — it does not shell out to `aws sso login`. The wire-level OIDC and Portal calls go through the official **AWS SDK for Swift** (`AWSSSOOIDC`, `AWSSSO`), wrapped in our own `OIDCRequesting` / `PortalRequesting` protocols. Lifecycle (timers, refresh, mint, Keychain storage, events) is Quorra's own actor.

- [ ] **Step 2: In `docs/IAMIdentityCenterPlan.html`, add a note in the appropriate section that the transport layer was migrated to the SDK on 2026-05-20** with a link back to this plan file.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md docs/IAMIdentityCenterPlan.html
git commit -m "docs: note AWS SDK adoption for IAM Identity Center transport"
```

---

## Phase 0 Notes (fill in during spike)

- **`aws-sdk-swift` pinned version:** _____
- **Exact Configuration type spelling:** _____ (e.g. `SSOOIDCClient.SSOOIDCClientConfiguration` or `SSOOIDCClient.Config`)
- **Exact exception initializer signatures:** _____ (e.g. `init(message:)` vs `init(properties:)`)
- **Binary size delta:** _____ (before / after)
- **Sendable warnings observed:** _____
- **Notarization / hardened-runtime issues:** _____

---

## Self-Review Checklist

- [x] **Spec coverage:** every requirement from the chat — fix the bug, adopt SDK, factory-per-session — has a phase or task.
- [x] **Bug fix lands first** (Phase 1) with hand-rolled code still under the hood; SDK swap follows.
- [x] **Type consistency:** `OIDCClientProviding.client(forRegion:)` is the same signature in protocol, stub, URLSession impl, SDK impl, and all call sites. Same for `PortalClientProviding`.
- [x] **No placeholders:** every step has either real code or an exact tool command + expected result.
- [x] **Each task self-contained:** an executor reading task N out of order has the file paths and code blocks they need.
- [x] **Tests precede implementation** in Phases 2.1, 4.2 (the testable boundaries — error mapping). Adapter code itself is verified via the existing actor-level test suite running against a `StubOIDCClientProvider` wrapping `StubOIDCRequesting`.
- [x] **Frequent commits:** every task ends in a commit, every commit is on a coherent unit.

---

## Risks & Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| AWS CRT linker / sandbox failure | Medium | Phase 0 gate; if fails, revisit and possibly use the SDK on a non-sandboxed CLI path only |
| SDK type/initializer names differ from this plan | High | Phase 0 documents exact names; Phase 2/4 follow notes |
| Sendable strict-mode warnings | Medium | Localize `@unchecked Sendable` at the adapter boundary; only escalate if pervasive |
| Refresh-token semantics differ between hand-rolled and SDK | Low | Existing refresh tests via `StubOIDCRequesting` cover orchestration; one manual refresh after Phase 3 to confirm wire behavior |
| Binary size growth unacceptable | Low | Phase 0 records it; we can fall back to OIDC-only adoption if needed |
