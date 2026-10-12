import Foundation

/// A failure whose message is safe to print.
/// Messages never contain arguments, secrets or tool stderr.
public struct ToolingFailure: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// The process received a signal and stopped at the next safe point.
/// `status` is the shell-style exit status: 130, 143 or 129.
public struct Interrupted: Error, Equatable {
    public let status: Int32
}

public func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw ToolingFailure(message()) }
}

public func standardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
