// AWSConfigINI — public umbrella and type-alias hub.
//
// The primary public API entry point is `AWSConfigINIDocument`.
// Public types are re-exported from their individual files; this file
// provides the `AWSConfigINIDocument.Options` typealias for the plan §5 API shape.

import Foundation

// Typealiases to match the plan §5 public API shape.
// The concrete type is AWSConfigINIDocumentOptions (in Options.swift).
extension AWSConfigINIDocument {
    public typealias Options = AWSConfigINIDocumentOptions
}
