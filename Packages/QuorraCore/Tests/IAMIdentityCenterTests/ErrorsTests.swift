import Testing
import Foundation
@testable import IAMIdentityCenter

@Suite("IAMIdentityCenterError LocalizedError conformance")
struct ErrorsTests {

    @Test("Every error case has non-nil errorDescription")
    func allErrorsHaveDescription() {
        let errors: [IAMIdentityCenterError] = [
            .network(URLError(.notConnectedToInternet)),
            .malformedResponse("test"),
            .httpStatus(500, body: nil),
            .authorizationPending,
            .slowDown,
            .accessDenied,
            .expiredDeviceCode,
            .invalidGrant,
            .invalidClient,
            .userCancelled,
            .deviceFlowTimedOut,
            .awsError(code: "TestError", description: "Test description"),
            .keychainItemMissing(service: "test.service", account: "test.account"),
            .keychainStatus(errSecNotAvailable),
            .keychainMalformed(reason: "test reason"),
        ]

        for error in errors {
            #expect(error.errorDescription != nil, "\(error) has nil errorDescription")
        }
    }

    @Test("Network error includes underlying URLError description")
    func networkErrorDescription() {
        let urlError = URLError(.notConnectedToInternet)
        let error = IAMIdentityCenterError.network(urlError)
        let description = error.errorDescription ?? ""
        #expect(description.contains("Network error"))
    }

    @Test("HTTP status with body includes both code and body")
    func httpStatusWithBody() {
        let error = IAMIdentityCenterError.httpStatus(404, body: "Not Found")
        let description = error.errorDescription ?? ""
        #expect(description.contains("404"))
        #expect(description.contains("Not Found"))
    }

    @Test("HTTP status without body includes only code")
    func httpStatusWithoutBody() {
        let error = IAMIdentityCenterError.httpStatus(500, body: nil)
        let description = error.errorDescription ?? ""
        #expect(description.contains("500"))
    }

    @Test("AWS error includes code and optional description")
    func awsError() {
        let withDescription = IAMIdentityCenterError.awsError(code: "InvalidGrant", description: "Token expired")
        let desc1 = withDescription.errorDescription ?? ""
        #expect(desc1.contains("InvalidGrant"))
        #expect(desc1.contains("Token expired"))

        let withoutDescription = IAMIdentityCenterError.awsError(code: "Unknown", description: nil)
        let desc2 = withoutDescription.errorDescription ?? ""
        #expect(desc2.contains("Unknown"))
    }

    @Test("Keychain item missing includes service and account")
    func keychainItemMissing() {
        let error = IAMIdentityCenterError.keychainItemMissing(service: "test.service", account: "test.account")
        let description = error.errorDescription ?? ""
        #expect(description.contains("test.service"))
        #expect(description.contains("test.account"))
    }

    @Test("Some errors have recoverySuggestion")
    func someErrorsHaveRecoverySuggestion() {
        let networkError = IAMIdentityCenterError.network(URLError(.notConnectedToInternet))
        #expect(networkError.recoverySuggestion != nil)

        let expiredError = IAMIdentityCenterError.expiredDeviceCode
        #expect(expiredError.recoverySuggestion != nil)

        let missingError = IAMIdentityCenterError.keychainItemMissing(service: "s", account: "a")
        #expect(missingError.recoverySuggestion != nil)
    }
}
