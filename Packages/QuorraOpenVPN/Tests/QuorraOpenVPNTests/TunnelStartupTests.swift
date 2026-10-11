import QuorraOpenVPNTestSupport
import Testing

@Suite("Native tunnel startup contract")
struct TunnelStartupTests {
    @Test(arguments: [0, 1, 2, 3])
    func startupWaitsForSettingsAndHandlesRejectionCancellationAndTimeout(scenario: Int) {
        #expect(QVPNTestTunnelStartupContract(scenario))
    }
}
