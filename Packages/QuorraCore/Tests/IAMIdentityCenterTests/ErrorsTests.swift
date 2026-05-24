import Testing
import Foundation
@testable import IAMIdentityCenter

@Suite("IAMIdentityCenterError LocalizedError conformance")
struct ErrorsTests {
    @Test func dynamicDescriptionsPreserveUsefulContext() {
        let cases: [(IAMIdentityCenterError, [String])] = [
            (.network(URLError(.notConnectedToInternet)), ["Network error"]),
            (.httpStatus(404, body: "Not Found"), ["404", "Not Found"]),
            (.awsError(code: "InvalidGrant", description: "Token expired"), ["InvalidGrant", "Token expired"]),
            (.keychainItemMissing(service: "test.service", account: "test.account"), ["test.service", "test.account"]),
        ]

        for (error, expectedFragments) in cases {
            let description = error.errorDescription ?? ""
            for fragment in expectedFragments {
                #expect(description.contains(fragment))
            }
        }
    }

    @Test func actionableErrorsProvideRecoverySuggestions() {
        #expect(IAMIdentityCenterError.network(URLError(.notConnectedToInternet)).recoverySuggestion != nil)
        #expect(IAMIdentityCenterError.expiredDeviceCode.recoverySuggestion != nil)
        #expect(IAMIdentityCenterError.keychainItemMissing(service: "s", account: "a").recoverySuggestion != nil)
    }
}
