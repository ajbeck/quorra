import Testing
@testable import QuorraAppLogic

@Suite("Credential shell snippets")
struct CredentialShellTests {
    private func script(_ shell: CredentialShell, secret: String = "secret") -> [String] {
        shell.script(accessKeyId: "AKIAEXAMPLE", secretAccessKey: secret, sessionToken: "token", region: "eu-west-1")
            .components(separatedBy: "\n")
    }

    @Test func bashAndZshExportOneVariablePerLine() {
        let expected = [
            "export AWS_ACCESS_KEY_ID='AKIAEXAMPLE'",
            "export AWS_SECRET_ACCESS_KEY='secret'",
            "export AWS_SESSION_TOKEN='token'",
            "export AWS_REGION='eu-west-1'",
            "export AWS_DEFAULT_REGION='eu-west-1'",
        ]
        #expect(script(.bash) == expected)
        #expect(script(.zsh) == expected)
    }

    @Test func fishSetsGlobalExportedVariables() {
        #expect(script(.fish) == [
            "set -gx AWS_ACCESS_KEY_ID 'AKIAEXAMPLE'",
            "set -gx AWS_SECRET_ACCESS_KEY 'secret'",
            "set -gx AWS_SESSION_TOKEN 'token'",
            "set -gx AWS_REGION 'eu-west-1'",
            "set -gx AWS_DEFAULT_REGION 'eu-west-1'",
        ])
    }

    @Test func powershellAssignsTheEnvDrive() {
        #expect(script(.powershell) == [
            "$env:AWS_ACCESS_KEY_ID = 'AKIAEXAMPLE'",
            "$env:AWS_SECRET_ACCESS_KEY = 'secret'",
            "$env:AWS_SESSION_TOKEN = 'token'",
            "$env:AWS_REGION = 'eu-west-1'",
            "$env:AWS_DEFAULT_REGION = 'eu-west-1'",
        ])
    }

    @Test func quotesAndBackslashesInValuesStayLiteral() {
        let value = "a'b\\c"
        #expect(script(.bash, secret: value)[1] == "export AWS_SECRET_ACCESS_KEY='a'\\''b\\c'")
        #expect(script(.fish, secret: value)[1] == "set -gx AWS_SECRET_ACCESS_KEY 'a\\'b\\\\c'")
        #expect(script(.powershell, secret: value)[1] == "$env:AWS_SECRET_ACCESS_KEY = 'a''b\\c'")
    }
}
