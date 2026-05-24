import Testing
import Foundation
@testable import AWSConfigINI

@Suite("AWSConfigINIError - LocalizedError")
struct AWSConfigINIErrorTests {
    private let sampleURL = URL(fileURLWithPath: "/Users/test/.aws/config")
    private let sampleMessage = "something went wrong"

    @Test func descriptionsPreserveActionableContext() {
        let cases: [(AWSConfigINIError, [String])] = [
            (.fileNotFound(sampleURL), ["/Users/test/.aws/config"]),
            (.ioError(sampleURL, underlying: CocoaError(.fileReadNoSuchFile)), ["config"]),
            (.lockTimeout(sampleURL), ["config"]),
            (.readOnly(sampleURL), ["config"]),
            (.decodeError(sampleMessage), [sampleMessage]),
            (.encodeError(sampleMessage), [sampleMessage]),
            (.malformedInput(sampleMessage), [sampleMessage]),
        ]

        for (error, fragments) in cases {
            let description = error.errorDescription ?? ""
            for fragment in fragments {
                #expect(description.contains(fragment))
            }
        }
    }

    @Test func onlyActionableFileErrorsHaveRecoverySuggestions() {
        #expect(AWSConfigINIError.lockTimeout(sampleURL).recoverySuggestion != nil)
        #expect(AWSConfigINIError.readOnly(sampleURL).recoverySuggestion != nil)
        #expect(AWSConfigINIError.ioError(sampleURL, underlying: CocoaError(.fileReadNoSuchFile)).recoverySuggestion != nil)
        #expect(AWSConfigINIError.fileNotFound(sampleURL).recoverySuggestion == nil)
        #expect(AWSConfigINIError.decodeError(sampleMessage).recoverySuggestion == nil)
    }
}
