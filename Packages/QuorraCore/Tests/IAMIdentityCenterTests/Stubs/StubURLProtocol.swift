import Foundation

/// Test seam for hermetic URLSession-based tests.
///
/// Registers stubbed responses keyed by URL substring matching.
/// Use `StubURLProtocol.register(...)` to configure responses per test.
internal final class StubURLProtocol: URLProtocol {
    // MARK: - Registration

    // Access is protected by `lock` — safe to use `nonisolated(unsafe)` per Swift 6.2 concurrency guidelines
    private nonisolated(unsafe) static var stubs: [String: StubResponse] = [:]
    private static let lock = NSLock()

    internal enum StubResponse {
        case success(Data, HTTPURLResponse)
        case failure(Error)
        case custom((URLRequest) -> (Data, HTTPURLResponse))
    }

    /// Registers a stubbed response for URLs containing the given substring.
    ///
    /// - Parameters:
    ///   - urlSubstring: Substring to match (e.g. "/logout")
    ///   - response: Stubbed response data
    static func register(urlSubstring: String, response: StubResponse) {
        lock.lock()
        defer { lock.unlock() }
        stubs[urlSubstring] = response
    }

    /// Clears all registered stubs.
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        stubs.removeAll()
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url?.absoluteString else { return false }
        lock.lock()
        defer { lock.unlock() }
        // Only handle requests that have a matching stub
        let hasMatch = stubs.keys.contains { url.contains($0) }
        return hasMatch && !stubs.isEmpty
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url?.absoluteString else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        let stub = Self.stubs.first { url.contains($0.key) }?.value
        Self.lock.unlock()

        guard let stub = stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        switch stub {
        case .success(let data, let response):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .custom(let handler):
            let (data, response) = handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

// MARK: - Helpers

extension StubURLProtocol {
    /// Creates a stubbed URLSession configured to use StubURLProtocol.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Convenience: register a success response with JSON body.
    static func registerSuccess(
        urlSubstring: String,
        statusCode: Int = 200,
        json: [String: Any]
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        let url = URL(string: "https://stub.local\(urlSubstring)")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        register(urlSubstring: urlSubstring, response: .success(data, response))
    }

    /// Convenience: register a network failure.
    static func registerNetworkFailure(urlSubstring: String) {
        register(urlSubstring: urlSubstring, response: .failure(URLError(.notConnectedToInternet)))
    }

    /// Convenience: register a custom handler for dynamic per-call responses.
    static func registerCustom(
        urlSubstring: String,
        handler: @escaping (URLRequest) -> (Data, HTTPURLResponse)
    ) {
        register(urlSubstring: urlSubstring, response: .custom(handler))
    }
}
