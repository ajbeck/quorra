import Foundation

/// `OIDCClientProviding` implementation that builds and caches `SDKOIDCClient` instances
/// keyed by AWS region.
///
/// One SDK client per region; constructed lazily on first request. The actor isolates the
/// cache map — SDK clients themselves are documented thread-safe and are not mutated after init.
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
