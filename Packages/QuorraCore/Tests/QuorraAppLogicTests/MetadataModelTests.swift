import Foundation
import Testing
@testable import QuorraAppLogic

@Suite("Metadata models")
struct MetadataModelTests {
    @Test func folder_assignments_have_stable_object_keys() {
        let key = MetadataFolderAssignment.objectKey(
            kind: .profile,
            objectID: "ac:cp:org_admin"
        )

        #expect(key == "profile:ac:cp:org_admin")
    }

    @Test func imds_endpoint_definitions_expose_loopback_urls() {
        let endpoint = IMDSEndpointDefinition(
            name: "Terraform",
            profileName: "ac:cp:org_admin",
            port: 9678
        )

        #expect(endpoint.endpointURL?.absoluteString == "http://127.0.0.1:9678")
    }

    @Test func imds_endpoint_log_limit_matches_product_decision() {
        #expect(IMDSEndpointLogStore.maxEntriesPerEndpoint == 1_000)
    }
}
