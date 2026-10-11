import Foundation
import Testing
@testable import ClientVPN

@Suite("Client VPN wire format")
struct ClientVPNWireTests {
    private static let run = UUID()
    private static let token = ClientVPNLiveToken(username: Data("user".utf8), token: Data("token".utf8))

    @Test(arguments: [
        ClientVPNLiveRequest.connect(run: run, profile: "client\nremote vpn.example.invalid 443\n", token: nil),
        .connect(run: run, profile: "client", token: token),
        .authenticate(run: run, challenge: UUID(), assertion: Data("assertion".utf8)),
        .status(run: run),
        .stop(run: run),
    ])
    func requestsRoundTrip(request: ClientVPNLiveRequest) throws {
        #expect(try ClientVPNWire.decodeRequest(ClientVPNWire.encode(request)) == request)
    }

    @Test(arguments: [
        ClientVPNLiveResponse.snapshot(.init(run: run, phase: .awaitingProfile)),
        .snapshot(.init(run: run, phase: .authenticating, challenge: .init(id: UUID(), url: URL(string: "https://signin.example.invalid/saml?RelayState=a%20b")!), packets: .init(sent: 1, received: 2))),
        .snapshot(.init(run: run, phase: .running, token: token, packets: .init(sent: .max, received: 0))),
        .snapshot(.init(run: run, phase: .failed, failure: .timedOut)),
        .rejected(.staleRequest),
    ])
    func responsesRoundTrip(response: ClientVPNLiveResponse) throws {
        #expect(try ClientVPNWire.decodeResponse(ClientVPNWire.encode(response)) == response)
    }

    @Test func largestAssertionFitsInOneMessage() throws {
        let request = ClientVPNLiveRequest.authenticate(run: Self.run, challenge: UUID(), assertion: Data(repeating: 65, count: ClientVPNLimits.credentialBytes))
        let bytes = try ClientVPNWire.encode(request)
        #expect(bytes.count <= ClientVPNLimits.messageBytes)
        #expect(try ClientVPNWire.decodeRequest(bytes) == request)
    }

    @Test func encodingEnforcesTheLimits() throws {
        let profile = String(repeating: "a", count: ClientVPNLimits.profileBytes)
        _ = try ClientVPNWire.encode(.connect(run: Self.run, profile: profile, token: nil))
        #expect(throws: ClientVPNLiveFailure.invalidProfile) { try ClientVPNWire.encode(.connect(run: Self.run, profile: profile + "a", token: nil)) }

        #expect(throws: ClientVPNLiveFailure.invalidCredentials) { try ClientVPNWire.encode(.authenticate(run: Self.run, challenge: UUID(), assertion: Data())) }
        let oversized = Data(count: ClientVPNLimits.credentialBytes + 1)
        #expect(throws: ClientVPNLiveFailure.invalidCredentials) { try ClientVPNWire.encode(.authenticate(run: Self.run, challenge: UUID(), assertion: oversized)) }

        let username = Data(count: ClientVPNLimits.tokenUsernameBytes)
        _ = try ClientVPNWire.encode(.connect(run: Self.run, profile: "client", token: .init(username: username, token: Data([1]))))
        let longUsername = ClientVPNLiveToken(username: username + Data([1]), token: Data([1]))
        #expect(throws: ClientVPNLiveFailure.invalidCredentials) { try ClientVPNWire.encode(.connect(run: Self.run, profile: "client", token: longUsername)) }
        let halfToken = ClientVPNLiveToken(username: Data([1]), token: Data())
        #expect(throws: ClientVPNLiveFailure.invalidCredentials) { try ClientVPNWire.encode(.connect(run: Self.run, profile: "client", token: halfToken)) }

        // Each part fits, but together they exceed one message.
        let bigToken = ClientVPNLiveToken(username: Data([1]), token: Data(count: ClientVPNLimits.credentialBytes - 1))
        #expect(throws: ClientVPNWireError.tooLarge) { try ClientVPNWire.encode(.connect(run: Self.run, profile: profile, token: bigToken)) }
    }

    @Test func decodingRejectsDamagedMessages() throws {
        let bytes = try ClientVPNWire.encode(.authenticate(run: Self.run, challenge: UUID(), assertion: Data("assertion".utf8)))
        for count in 0..<bytes.count {
            #expect(throws: (any Error).self) { try ClientVPNWire.decodeRequest(bytes.prefix(count)) }
        }
        #expect(throws: ClientVPNWireError.malformed) { try ClientVPNWire.decodeRequest(bytes + Data([0])) }

        var wrongMagic = bytes
        wrongMagic[0] = 0
        #expect(throws: ClientVPNWireError.malformed) { try ClientVPNWire.decodeRequest(wrongMagic) }
        var newerVersion = bytes
        newerVersion[4] = 2
        #expect(throws: ClientVPNWireError.unsupportedVersion) { try ClientVPNWire.decodeRequest(newerVersion) }
        var unknownKind = bytes
        unknownKind[5] = 99
        #expect(throws: ClientVPNWireError.malformed) { try ClientVPNWire.decodeRequest(unknownKind) }

        let response = try ClientVPNWire.encode(ClientVPNLiveResponse.rejected(.busy))
        #expect(throws: ClientVPNWireError.malformed) { try ClientVPNWire.decodeRequest(response) }
        #expect(throws: ClientVPNWireError.malformed) { try ClientVPNWire.decodeResponse(bytes) }
    }

    @Test func decodingEnforcesTheLimits() throws {
        let profile = Data(repeating: 97, count: ClientVPNLimits.profileBytes + 1)
        #expect(throws: ClientVPNWireError.malformed) { try ClientVPNWire.decodeRequest(Self.connect(profile: profile, username: Data(), token: Data())) }
        #expect(throws: ClientVPNWireError.malformed) { try ClientVPNWire.decodeRequest(Self.connect(profile: Data([0xFF]), username: Data(), token: Data())) }
        #expect(throws: ClientVPNWireError.malformed) { try ClientVPNWire.decodeRequest(Self.connect(profile: Data("client".utf8), username: Data([1]), token: Data())) }
        #expect(throws: ClientVPNWireError.malformed) { try ClientVPNWire.decodeRequest(Data(count: ClientVPNLimits.messageBytes + 1)) }
    }

    @Test func descriptionsRedactContents() {
        let request = ClientVPNLiveRequest.authenticate(run: Self.run, challenge: UUID(), assertion: Data("secret-assertion".utf8))
        #expect(!String(reflecting: request).contains("secret"))
        #expect(String(reflecting: Self.token) == "VPN session token (redacted)")
    }

    @Test func failuresSurviveTheTripFromTheExtension() {
        let sent = ClientVPNLiveFailure.authentication as NSError
        let received = NSError(domain: sent.domain, code: sent.code, userInfo: sent.userInfo)
        #expect(ClientVPNLiveFailure(providerError: received) == .authentication)
        #expect(received.localizedDescription == ClientVPNLiveFailure.authentication.errorDescription)
        #expect(ClientVPNLiveFailure(providerError: NSError(domain: "unrelated", code: sent.code)) == nil)
        #expect(ClientVPNLiveFailure(providerError: NSError(domain: sent.domain, code: 999)) == nil)
    }

    /// A connect request built by hand, to send what `encode` refuses to.
    private static func connect(profile: Data, username: Data, token: Data) -> Data {
        var data = Data("QVPN".utf8) + Data([1, 1])
        withUnsafeBytes(of: run.uuid) { data.append(contentsOf: $0) }
        for field in [profile, username, token] {
            withUnsafeBytes(of: UInt32(field.count).bigEndian) { data.append(contentsOf: $0) }
            data.append(field)
        }
        return data
    }
}
