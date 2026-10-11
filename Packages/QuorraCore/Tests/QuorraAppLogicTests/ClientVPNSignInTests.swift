import ClientVPN
import Foundation
import LoopbackCallback
import Testing
@testable import QuorraAppLogic

@Suite("Loopback request framing")
struct LoopbackHTTPRequestTests {
    private let limits = LoopbackHTTPRequest.Limits(header: 64, body: 16)

    @Test func waitsForTheWholeRequest() throws {
        #expect(try LoopbackHTTPRequest(parsing: Data("GET / HTTP/1.1\r\nHost: a".utf8), limits: limits) == nil)
        #expect(try LoopbackHTTPRequest(parsing: Data("POST / HTTP/1.1\r\nContent-Length: 4\r\n\r\nab".utf8), limits: limits) == nil)
        let request = try #require(try LoopbackHTTPRequest(parsing: Data("POST /x HTTP/1.1\r\nContent-Length: 4\r\n\r\nabcd".utf8), limits: limits))
        #expect(request.method == "POST" && request.target == "/x" && request.body == Data("abcd".utf8))
    }

    @Test(arguments: [
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\na",
        "POST / HTTP/1.1\r\nContent-Length: +1\r\n\r\na",
        "POST / HTTP/1.1\r\nContent-Length: 17\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: 9223372036854775807\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: 1\r\n\r\nab",
        "POST / HTTP/1.0\r\n\r\n",
        "POST / HTTP/1.1\r\nNo separator\r\n\r\n",
    ])
    func refusesAmbiguousFraming(request: String) {
        #expect(throws: LoopbackHTTPRequestError.self) { try LoopbackHTTPRequest(parsing: Data(request.utf8), limits: limits) }
    }

    @Test func refusesAnOversizedHeader() {
        #expect(throws: LoopbackHTTPRequestError.self) { try LoopbackHTTPRequest(parsing: Data(repeating: 65, count: 65), limits: limits) }
    }
}

@Suite("Client VPN SAML callback")
struct ClientVPNSAMLCallbackTests {
    private func request(_ body: String, extra: String = "") throws -> LoopbackHTTPRequest {
        let bytes = Data("POST / HTTP/1.1\r\nHost: 127.0.0.1:35001\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: \(body.utf8.count)\r\n\(extra)\r\n\(body)".utf8)
        return try #require(try LoopbackHTTPRequest(parsing: bytes, limits: ClientVPNSAMLCallback.limits))
    }

    @Test func acceptsOneAssertionWithTheMatchingRelayState() throws {
        let callback = try request("SAMLResponse=c3ludGhldGlj&RelayState=expected")
        #expect(try ClientVPNSAMLCallback.assertion(from: callback, port: 35_001, relayState: "expected") == "c3ludGhldGlj")
        #expect(throws: ClientVPNLiveFailure.authentication) { try ClientVPNSAMLCallback.assertion(from: callback, port: 35_001, relayState: "different") }
    }

    @Test(arguments: [
        "SAMLResponse=QQ%3D%3D&SAMLResponse=Qg%3D%3D",
        "SAMLResponse=QQ%3D%3D&RelayState=a&RelayState=b",
        "SAMLResponse=not-base64",
        "SAMLResponse=QQ%3D%3D&unexpected=x",
        "SAMLResponse=",
    ])
    func refusesAmbiguousOrMalformedForms(body: String) throws {
        let callback = try request(body)
        #expect(throws: ClientVPNLiveFailure.authentication) { try ClientVPNSAMLCallback.assertion(from: callback, port: 35_001, relayState: nil) }
    }

    @Test func refusesTheWrongHostOrMethod() throws {
        let duplicateHost = try request("SAMLResponse=QQ%3D%3D", extra: "Host: 127.0.0.1:35001\r\n")
        #expect(throws: ClientVPNLiveFailure.authentication) { try ClientVPNSAMLCallback.assertion(from: duplicateHost, port: 35_001, relayState: nil) }
        let get = try #require(try LoopbackHTTPRequest(parsing: Data("GET /?SAMLResponse=QQ%3D%3D HTTP/1.1\r\nHost: 127.0.0.1:35001\r\n\r\n".utf8), limits: ClientVPNSAMLCallback.limits))
        #expect(throws: ClientVPNLiveFailure.authentication) { try ClientVPNSAMLCallback.assertion(from: get, port: 35_001, relayState: nil) }
    }

    @Test func refusesAnAssertionOverTheLimit() throws {
        let assertion = Data(repeating: 65, count: ClientVPNLimits.credentialBytes).base64EncodedString()
        let callback = try request("SAMLResponse=\(assertion.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)")
        #expect(throws: ClientVPNLiveFailure.invalidCredentials) { try ClientVPNSAMLCallback.assertion(from: callback, port: 35_001, relayState: nil) }
    }

    @Test func thePagesEscapeTheProfileName() {
        let page = ClientVPNCallbackPage.received(profileName: "<b>vpn</b>").html
        #expect(page.contains("&lt;b&gt;vpn&lt;/b&gt;") && !page.contains("<b>"))
        #expect(page.contains("Close this tab"))
    }
}

@Suite("Client VPN browser sign-in")
@MainActor
struct ClientVPNBrowserSignInTests {
    @Test func returnsTheAssertionPostedToTheCallback() async throws {
        let port: UInt16 = 35_871
        let challenge = ClientVPNBrowserChallenge(id: UUID(), url: URL(string: "https://signin.example.invalid/saml?RelayState=relay")!)
        let posted = PostedForm()
        let signIn = ClientVPNBrowserSignIn(open: { _ in
            posted.task = Task {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data("SAMLResponse=c3ludGhldGlj&RelayState=relay".utf8)
                let (body, response) = try await URLSession(configuration: .ephemeral).data(for: request)
                return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: body, as: UTF8.self))
            }
            return true
        }, port: port)
        let assertion = try await signIn.assertion(for: challenge, profileName: "work")
        #expect(assertion == Data("c3ludGhldGlj".utf8))
        let (status, page) = try #require(try await posted.task?.value)
        #expect(status == 200 && page == ClientVPNCallbackPage.received(profileName: "work").html)
    }

    @Test func refusesAChallengeThatIsNotHTTPS() async {
        let signIn = ClientVPNBrowserSignIn(open: { _ in Issue.record("Opened an unsafe URL"); return true }, port: 35_872)
        let challenge = ClientVPNBrowserChallenge(id: UUID(), url: URL(string: "http://signin.example.invalid/")!)
        await #expect(throws: ClientVPNLiveFailure.authentication) { try await signIn.assertion(for: challenge, profileName: "work") }
    }
}

/// Holds the browser's POST, started inside the `open` callback, so the test can await it.
@MainActor
private final class PostedForm {
    var task: Task<(Int, String), any Error>?
}
