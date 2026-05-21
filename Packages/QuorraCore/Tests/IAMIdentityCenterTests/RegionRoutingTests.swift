import Testing
import Foundation
@testable import IAMIdentityCenter

/// Proves that `signIn(region:)` asks the provider for that exact region.
///
/// This is the regression test for the production bug where a single fixed-region
/// `OIDCClient` was shared across all sessions — sign-ins for any session whose
/// region differed from the hardcoded `us-east-1` got rejected with
/// `invalid_request: Invalid start url provided`. With the `OIDCClientProviding`
/// seam in place, the actor asks the provider for a client keyed on the caller-supplied
/// region; this test pins that behavior so the bug cannot regress.
@Suite struct RegionRoutingTests {

    @Test func signInAsksProviderForSessionRegion() async throws {
        // Region-faithful: each per-region stub registers a client carrying that region, so
        // pollForToken's lookup (keyed off client.region) stays on the same region — exactly
        // as the production SDK adapter behaves.
        let provider = StubOIDCClientProvider(factory: { region in StubOIDCRequesting(registerRegion: region) })
        let service = IdentityCenterService(
            keychain: InMemoryKeychainStore(),
            oidcClientProvider: provider
        )

        // The sign-in may not actually complete (the stub's default canned device-code
        // poll succeeds, but the test doesn't care about the outcome — only about
        // whether the actor asked the provider for the right region).
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
