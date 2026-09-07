import Foundation

struct QuorraCLIRuntimeError: LocalizedError, CustomStringConvertible, Sendable {
    let description: String

    var errorDescription: String? { description }
}
