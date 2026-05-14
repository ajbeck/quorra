import Foundation

/// Minimal caller for the IAM Identity Center Portal /logout endpoint.
///
/// This is intentionally NOT a full `PortalClient` (that's Scope B). Its only job is to
/// fire the best-effort server-side invalidation during sign-out per D3.
///
/// Endpoint: `POST https://portal.sso.<region>.amazonaws.com/logout`
/// Auth header: `x-amz-sso_bearer_token: <accessToken>`
///
/// Per SSODeviceAuth.html §04: logout is best-effort. The caller decides what to do on error;
/// this type just throws so the caller can distinguish network failures.
///
/// `URLSession` is injected for testability (use `StubURLProtocol.makeSession()` in tests).
struct PortalLogout: Sendable {
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    /// Sends `POST /logout` to the Identity Center Portal for `region`.
    ///
    /// - Parameters:
    ///   - accessToken: The bearer access token to invalidate.
    ///   - region: AWS region string (e.g. `"us-east-1"`).
    /// - Throws: `IAMIdentityCenterError.network` on transport failure,
    ///   `IAMIdentityCenterError.httpStatus` on non-200 response.
    func logout(accessToken: String, region: String) async throws {
        let url = URL(string: "https://portal.sso.\(region).amazonaws.com/logout")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(accessToken, forHTTPHeaderField: "x-amz-sso_bearer_token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (_, response) = try await urlSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 {
                throw IAMIdentityCenterError.httpStatus(httpResponse.statusCode, body: nil)
            }
        } catch let error as IAMIdentityCenterError {
            throw error
        } catch let urlError as URLError {
            throw IAMIdentityCenterError.network(urlError)
        }
    }
}
