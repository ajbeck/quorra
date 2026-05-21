import Foundation
@testable import IAMIdentityCenter

/// Test double for `OIDCClientProviding` that records every region request and returns a
/// per-region `StubOIDCRequesting` so tests can assert routing.
///
/// Use `makeStubOIDCProvider(_:)` (in `TestHelpers.swift`) when a test wants the same stub
/// for every region (the common case). Use this directly when a test wants to assert which
/// regions were asked for.
actor StubOIDCClientProvider: OIDCClientProviding {
    private(set) var regionRequests: [String] = []
    private var stubs: [String: StubOIDCRequesting] = [:]
    private let factory: @Sendable (String) -> StubOIDCRequesting

    init(factory: @escaping @Sendable (String) -> StubOIDCRequesting) {
        self.factory = factory
    }

    func client(forRegion region: String) async throws -> any OIDCRequesting {
        regionRequests.append(region)
        if let cached = stubs[region] { return cached }
        let stub = factory(region)
        stubs[region] = stub
        return stub
    }

    func stub(forRegion region: String) -> StubOIDCRequesting? {
        stubs[region]
    }
}
