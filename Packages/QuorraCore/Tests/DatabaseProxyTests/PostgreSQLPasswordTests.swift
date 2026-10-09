import Foundation
import Testing
@testable import DatabaseProxy

struct PostgreSQLPasswordTests {
    @Test func scramClientMatchesIndependentServerVectorAndRejectsFalseServerProof() throws {
        let nonce = "rOprNGfwEbeRWgbNEkqO"
        var client = try PostgreSQLSCRAMClient(nonce: nonce)
        let challenge = "r=\(nonce)%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
        let final = try client.respond(password: "pencil", challenge: challenge)
        // The local server implementation and RFC7677 test use a different
        // PBKDF implementation; verify both directions of this transcript.
        let server = try PostgreSQLSCRAM(password: "pencil", clientFirst: client.first,
                                         salt: #require(Data(base64Encoded: "W22ZaJ0SNY7soEsUEjb6gQ==")),
                                         serverNonce: "%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0")
        try client.verify(server.finish(final))
        #expect(throws: ProxyError.upstreamPasswordAuthentication) { try client.verify("v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=") }
        #expect(throws: ProxyError.upstreamPasswordAuthentication) { try client.verify("e=invalid-proof") }
        #expect(throws: ProxyError.malformedMessage) { try client.verify("v=one,v=two") }
        #expect(String(describing: client) == "PostgreSQLSCRAMClient(redacted)")
    }

    @Test func rejectsInvalidSCRAMChallengesBeforePasswordDerivation() throws {
        let nonce = "abcdefghijklmnop"
        for challenge in ["r=wrongnonce,s=c2FsdA==,i=4096", "r=\(nonce),s=c2FsdA==,i=4096",
                          "r=\(nonce)server,s=c2FsdA==,i=0", "r=\(nonce)server,s=c2FsdA==,i=999999999",
                          "r=\(nonce)server,s=invalid,i=4096", "m=required,r=\(nonce)server,s=c2FsdA==,i=4096"] {
            var client = try PostgreSQLSCRAMClient(nonce: nonce)
            #expect(throws: ProxyError.upstreamPasswordAuthentication) { try client.respond(password: "synthetic", challenge: challenge) }
        }
    }

    @Test func passwordAndIAMAuthenticationRejectUnexpectedTransitions() throws {
        let login = DatabaseLogin(username: "user", password: "password")
        var password = try PostgreSQLPasswordAuthentication(login: login, iam: false)
        #expect(throws: ProxyError.upstreamPasswordAuthentication) { try password.respond(to: PostgreSQLWire.integer(0)) }
        #expect(try password.respond(to: PostgreSQLWire.integer(3)) == Data("password\0".utf8))
        #expect(throws: ProxyError.upstreamPasswordAuthentication) { try password.respond(to: PostgreSQLWire.integer(3)) }
        #expect(try password.respond(to: PostgreSQLWire.integer(0)) == nil)
        #expect(password.complete)
        #expect(throws: ProxyError.upstreamPasswordAuthentication) { try password.respond(to: PostgreSQLWire.integer(0)) }
        var iam = try PostgreSQLPasswordAuthentication(login: login, iam: true)
        #expect(throws: ProxyError.upstreamAuthentication) {
            try iam.respond(to: PostgreSQLWire.integer(10) + Data("SCRAM-SHA-256\0\0".utf8))
        }
        var plusOnly = try PostgreSQLPasswordAuthentication(login: login, iam: false)
        #expect(throws: ProxyError.unsupportedAuthentication) {
            try plusOnly.respond(to: PostgreSQLWire.integer(10) + Data("SCRAM-SHA-256-PLUS\0\0".utf8))
        }
    }

    @Test func saslprepMatchesPostgreSQLMappingAndRawPasswordFallback() {
        for (raw, expected) in [("I\u{00AD}X", "IX"), ("user", "user"), ("USER", "USER"),
                                ("\u{00AA}", "a"), ("\u{2168}", "IX"), ("a\u{00A0}b", "a b"),
                                ("a\u{200B}b", "a b"), ("\u{00AD}", "\u{00AD}"),
                                ("\u{0627}1\u{0628}", "\u{0627}1\u{0628}"),
                                ("a\u{0627}", "a\u{0627}"), ("\u{0221}", "\u{0221}")] {
            #expect(PostgreSQLSASLPrep.password(raw) == expected)
        }
    }
}

@MainActor
struct PasswordConnectionValidationTests {
    @Test func IAMCannotDisableTLSOrAcceptAnUnrelatedBinding() async throws {
        let fixture = try await ProxyCredentialFixture()
        var value = fixture.configuration(upstreamPort: 5432, localPort: 15432).draft
        value.tlsMode = .disabled
        #expect(throws: ConfigurationError.iamRequiresTLS) { try value.connection(credentialID: fixture.credentialID) }
        var password = DatabaseConnectionDraft(name: "Password database", host: "localhost", database: "app",
                                               authentication: .databasePassword, passwordCredentialID: UUID())
        let summary = DatabaseConnectionSummary(id: UUID(), draft: password, credentialID: password.passwordCredentialID!, sessionName: "")
        #expect(throws: ConfigurationError.unsupportedConfiguration) { try summary.validate(binding: fixture.binding) }
        password.passwordCredentialID = nil
        #expect(throws: ConfigurationError.missingCredential) { try password.connection(credentialID: UUID()) }
    }
}
