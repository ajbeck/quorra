import Foundation
import Testing
@testable import DatabaseProxy

struct PostgreSQLProtocolTests {
    @Test func scramMatchesRFC7677AndRejectsBadProofNonceAndChannelBinding() throws {
        let challenge = try PostgreSQLSCRAM(password: "pencil", clientFirst: "n,,n=user,r=rOprNGfwEbeRWgbNEkqO",
                                           salt: #require(Data(base64Encoded: "W22ZaJ0SNY7soEsUEjb6gQ==")),
                                           serverNonce: "%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0")
        #expect(challenge.serverFirst == "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")
        let final = "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="
        #expect(try challenge.finish(final) == "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")
        for bad in [final.replacingOccurrences(of: "dHzb", with: "aaaa"),
                    final.replacingOccurrences(of: "c=biws", with: "c=eSws"),
                    final.replacingOccurrences(of: "r=rOpr", with: "r=wrong"), final + ",p=duplicate"] {
            #expect(throws: ProxyError.localAuthentication) { try challenge.finish(bad) }
        }
        #expect(String(describing: challenge) == "PostgreSQLSCRAM(redacted)")
    }

    @Test func rejectsUnsupportedSASLAndMalformedStartupParameters() throws {
        for first in ["p=tls-server-end-point,,n=user,r=abcdefghijklmnop", "n,a=other,n=user,r=abcdefghijklmnop", "n,,n=u,r=short", "n,,n=u,r=abcdefghijklmnop,r=duplicate"] {
            #expect(throws: ProxyError.localAuthentication) {
                try PostgreSQLSCRAM(password: "synthetic", clientFirst: first, salt: Data([1]), serverNonce: "server")
            }
        }
        for value in ["user\0a\0user\0b\0\0", "user\0a\0", "user\0a\0\0junk", "user\0"] {
            #expect(throws: ProxyError.malformedMessage) { try PostgreSQLWire.parameters(Data(value.utf8)) }
        }
        let expected = ["user": " app_User ", "database": "db", "application_name": "integration test"]
        let startup = PostgreSQLWire.startup(expected)
        #expect(try PostgreSQLWire.uint32(Data(startup.prefix(4))) == UInt32(startup.count))
        #expect(try PostgreSQLWire.parameters(Data(startup.dropFirst(8))) == expected)
    }
}
