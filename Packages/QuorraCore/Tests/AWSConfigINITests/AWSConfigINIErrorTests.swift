import Testing
import Foundation
@testable import AWSConfigINI

@Suite("AWSConfigINIError — LocalizedError")
struct AWSConfigINIErrorTests {

    private let sampleURL = URL(fileURLWithPath: "/Users/test/.aws/config")
    private let sampleMessage = "something went wrong"

    @Test func fileNotFoundDescriptionContainsFullPath() {
        let error = AWSConfigINIError.fileNotFound(sampleURL)
        let desc = error.errorDescription
        #expect(desc != nil)
        // fileNotFound surfaces the full path (not just lastPathComponent) so the
        // user can tell which `~/.aws` they're missing.
        #expect(desc!.contains("/Users/test/.aws/config"))
    }

    @Test func ioErrorDescriptionContainsLastPathComponent() {
        let error = AWSConfigINIError.ioError(sampleURL, underlying: CocoaError(.fileReadNoSuchFile))
        let desc = error.errorDescription
        #expect(desc != nil)
        #expect(desc!.contains("config"))
    }

    @Test func lockTimeoutDescriptionContainsLastPathComponent() {
        let error = AWSConfigINIError.lockTimeout(sampleURL)
        let desc = error.errorDescription
        #expect(desc != nil)
        #expect(desc!.contains("config"))
    }

    @Test func readOnlyDescriptionContainsLastPathComponent() {
        let error = AWSConfigINIError.readOnly(sampleURL)
        let desc = error.errorDescription
        #expect(desc != nil)
        #expect(desc!.contains("config"))
    }

    @Test func decodeErrorDescriptionContainsMessage() {
        let error = AWSConfigINIError.decodeError(sampleMessage)
        let desc = error.errorDescription
        #expect(desc != nil)
        #expect(desc!.contains(sampleMessage))
    }

    @Test func encodeErrorDescriptionContainsMessage() {
        let error = AWSConfigINIError.encodeError(sampleMessage)
        let desc = error.errorDescription
        #expect(desc != nil)
        #expect(desc!.contains(sampleMessage))
    }

    @Test func malformedInputDescriptionContainsMessage() {
        let error = AWSConfigINIError.malformedInput(sampleMessage)
        let desc = error.errorDescription
        #expect(desc != nil)
        #expect(desc!.contains(sampleMessage))
    }

    @Test func lockTimeoutHasRecoverySuggestion() {
        let error = AWSConfigINIError.lockTimeout(sampleURL)
        #expect(error.recoverySuggestion != nil)
    }

    @Test func readOnlyHasRecoverySuggestion() {
        let error = AWSConfigINIError.readOnly(sampleURL)
        #expect(error.recoverySuggestion != nil)
    }

    @Test func ioErrorHasRecoverySuggestion() {
        let underlying = CocoaError(.fileReadNoSuchFile)
        let error = AWSConfigINIError.ioError(sampleURL, underlying: underlying)
        #expect(error.recoverySuggestion != nil)
    }

    @Test func fileNotFoundHasNoRecoverySuggestion() {
        #expect(AWSConfigINIError.fileNotFound(sampleURL).recoverySuggestion == nil)
    }

    @Test func decodeErrorHasNoRecoverySuggestion() {
        #expect(AWSConfigINIError.decodeError(sampleMessage).recoverySuggestion == nil)
    }

    @Test func encodeErrorHasNoRecoverySuggestion() {
        #expect(AWSConfigINIError.encodeError(sampleMessage).recoverySuggestion == nil)
    }

    @Test func malformedInputHasNoRecoverySuggestion() {
        #expect(AWSConfigINIError.malformedInput(sampleMessage).recoverySuggestion == nil)
    }
}
