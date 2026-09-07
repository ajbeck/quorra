import Testing
import QuorraIPC
@testable import QuorraCLIKit

@Suite("IMDS endpoint output")
struct IMDSEndpointRendererTests {
    @Test func tableUsesLiveProfileAndStableAddress() throws {
        let endpoint = makeEndpoint()

        let output = try IMDSEndpointRenderer.render([endpoint], format: .table)

        #expect(output.contains("running"))
        #expect(output.contains("http://127.0.0.1:7114"))
        #expect(output.contains("replacement-profile"))
        #expect(output.contains("Default IMDS Endpoint"))
    }

    @Test func jsonPreservesMachineReadableState() throws {
        let output = try IMDSEndpointRenderer.render([makeEndpoint()], format: .json)

        #expect(output.contains("\"status\" : \"running\""))
        #expect(output.contains("\"isDefault\" : true"))
        #expect(output.contains("\"configuredPort\" : 7114"))
    }

    private func makeEndpoint() -> QuorraIMDSEndpointRecord {
        QuorraIMDSEndpointRecord(
            id: "00000000-0000-0000-0000-000000007114",
            name: "Default IMDS Endpoint",
            profileName: "configured-profile",
            servedProfileName: "replacement-profile",
            bindAddress: "127.0.0.1",
            configuredPort: 7_114,
            boundPort: 7_114,
            status: .running,
            isDefault: true
        )
    }
}
