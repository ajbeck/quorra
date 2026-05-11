// AWSConfigINIDocument — top-level document type.
//
// M01 implements: init(_ string:), init(contentsOf:), init(empty:),
//                 sections, section(_:), bomKind, flavor.
// M03 implements: write() throws(AWSConfigINIError) -> String, write(to:). Decision D22.
// M04 implements: ensureSection(_:), deleteSection(_:), update(_:_:). Plan §10.2.
// M05 implements: update(at:flavor:options:_:). Plan §11.2 task 4; Decision D08.
// Decision D07: caller passes URLs explicitly; no env-var resolution in this module.

import Foundation

/// A parsed AWS shared-config INI document.
///
/// Wraps an ordered list of sections with their keys and associated comments.
/// The document carries the BOM kind and file flavor for round-trip and overlay use.
///
/// Decision D19: value type, `Sendable`, `mutating` methods.
public struct AWSConfigINIDocument: Sendable {
    // MARK: - Properties

    /// The file flavor (`.config` vs `.credentials`). Informs the AWS overlay (M07).
    public var flavor: FileFlavor

    /// If a BOM was present at the start of the input, its kind. `nil` if no BOM.
    /// Decision D17.
    public var bomKind: BOMKind?

    /// The line ending detected from the first `\r\n` or `\n` in the input.
    /// Defaults to `"\n"` for new/empty documents.
    public var lineEnding: String

    /// Leading comments that appear before any section header.
    public var leadingComments: [String]

    /// Ordered sections.
    var _sections: [Section]

    /// Global (pre-section) warnings collected during parsing.
    public var globalWarnings: [Warning]

    // MARK: - Initializers

    /// Parse `string` as an INI document of the given flavor.
    ///
    /// - Parameters:
    ///   - string: The raw INI text (already decoded from UTF-8 or equivalent).
    ///   - flavor: Whether this is a `.config` or `.credentials` file.
    ///   - options: Parse/write options; defaults to `.default`.
    /// - Throws: `AWSConfigINIError.malformedInput` (currently never thrown — the parser
    ///   is silent-tolerant per D06). Reserved for future hard-error cases.
    public init(_ string: String, flavor: FileFlavor = .config, options: AWSConfigINIDocumentOptions = .default) throws(AWSConfigINIError) {
        self.flavor = flavor
        self.lineEnding = AWSConfigINIDocument.detectLineEnding(in: string)
        self.bomKind = nil // BOM already stripped by caller or init(contentsOf:)
        let tokens = tokenize(string)
        let parseResult = parse(tokens: tokens)
        self._sections = parseResult.sections.map { parsed in
            Section(
                name: parsed.name,
                leadingComments: parsed.leadingComments,
                warnings: parsed.warnings,
                keys: parsed.keys.map { pk in
                    Key(
                        name: pk.name,
                        value: Self.convertValue(pk.value),
                        leadingComments: pk.leadingComments
                    )
                }
            )
        }
        self.leadingComments = parseResult.leadingComments
        self.globalWarnings = parseResult.globalWarnings
    }

    /// Reads and parses the file at `url`.
    ///
    /// - Throws:
    ///   - ``AWSConfigINIError/fileNotFound(_:)`` if the file does not exist.
    ///   - ``AWSConfigINIError/ioError(_:underlying:)`` for other read failures.
    ///   - ``AWSConfigINIError/malformedInput(_:)`` if the file is not valid UTF-8.
    ///
    /// Uses untyped `throws` because Swift 6.2 (Xcode 26) hits an
    /// `OSSACompleteLifetime` SIL crash when typed throws is combined with
    /// `try Data(contentsOf:)` inside an init body. The thrown value is still
    /// always an `AWSConfigINIError` — callers can downcast or use a
    /// `catch let e as AWSConfigINIError` clause for exhaustive handling.
    public init(contentsOf url: URL, flavor: FileFlavor = .config, options: AWSConfigINIDocumentOptions = .default) throws {
        let (string, detectedBOM) = try AWSConfigINIDocument.readFile(at: url)
        try self.init(string, flavor: flavor, options: options)
        self.bomKind = detectedBOM
    }

    /// Reads the file at `url`, strips any BOM, and returns the content as UTF-8 string.
    /// Untyped throws — see `init(contentsOf:)` for the SIL-crash rationale.
    /// Throws an `AWSConfigINIError` value in all cases.
    private static func readFile(at url: URL) throws -> (String, BOMKind?) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
                throw AWSConfigINIError.fileNotFound(url)
            }
            throw AWSConfigINIError.ioError(url, underlying: error)
        }
        let (bomKind, contentStart) = detectBOM(in: data)
        let contentData = contentStart > 0 ? data.dropFirst(contentStart) : data
        guard let string = String(data: contentData, encoding: .utf8) else {
            throw AWSConfigINIError.malformedInput("File at \(url.path) is not valid UTF-8")
        }
        return (string, bomKind)
    }

    /// Creates an empty document with no sections and no content.
    public init(empty flavor: FileFlavor) {
        self.flavor = flavor
        self.bomKind = nil
        self.lineEnding = "\n"
        self.leadingComments = []
        self._sections = []
        self.globalWarnings = []
    }

    // MARK: - Section access

    /// The ordered sections in this document.
    public var sections: [Section] { _sections }

    /// Returns the section with the given name, or `nil` if absent.
    /// Section names are case-sensitive.
    public func section(_ name: String) -> Section? {
        _sections.first(where: { $0.name == name })
    }

    /// Returns the section for the given profile name using the AWS overlay rules.
    ///
    /// Delegates to `FileFlavor.profileSectionName(for:)` (ProfileResolution.swift, M07).
    /// In `.config`: default → `"default"`, others → `"profile \(name)"`.
    /// In `.credentials`: any profile → `"\(name)"`.
    /// Parser spec §15.1; plan §13.2 task 2.
    public func profileSection(named name: String) -> Section? {
        section(flavor.profileSectionName(for: name))
    }

    // MARK: - Mutations (M04 — basic implementations here for M01 usability)

    /// Returns the existing section with `name`, or appends a new empty section and returns it.
    ///
    /// **Value-semantics caveat.** `Section` is a struct; the returned value is an independent
    /// copy. Mutating the returned section does NOT update the document. Use the
    /// `update(_:_:)` method for in-place mutation:
    ///
    /// ```swift
    /// doc.ensureSection("profile dev")          // guarantees the section exists
    /// doc.update("profile dev") { s in
    ///     s.setKey("region", value: "us-east-1")
    /// }
    /// ```
    ///
    /// The return value is useful for read-after-ensure (e.g. inspecting the initial state),
    /// not for mutation. Plan §10.2 task 4; Decision D19 (value types).
    @discardableResult
    public mutating func ensureSection(_ name: String) -> Section {
        if let idx = _sections.firstIndex(where: { $0.name == name }) {
            return _sections[idx]
        }
        let s = Section(name: name)
        _sections.append(s)
        return s
    }

    /// Removes the section with `name`. No-op if absent.
    public mutating func deleteSection(_ name: String) {
        _sections.removeAll(where: { $0.name == name })
    }

    /// Finds the section with `name` and passes it as `inout` to `block` for in-place mutation.
    /// No-op if the section does not exist.
    public mutating func update(_ name: String, _ block: (inout Section) -> Void) {
        guard let idx = _sections.firstIndex(where: { $0.name == name }) else { return }
        block(&_sections[idx])
    }

    // MARK: - Write (M03 — CanonicalWriter)

    /// Serializes the document to its canonical INI text representation.
    ///
    /// The output is semantically equivalent to the parsed input but not byte-identical.
    /// Separator spacing is normalized to ` = `, all string values are double-quoted (D15),
    /// and `[default]` is hoisted to the top (D16). BOM bytes are re-emitted if present (D17).
    ///
    /// - Returns: The canonical INI text, or `""` for an empty document.
    /// - Throws: `AWSConfigINIError.encodeError` if any value contains an unrepresentable
    ///   character (an embedded `"` or `\n`). Under normal parsing, values never contain
    ///   these characters — the error path is a safety net for programmatically constructed
    ///   documents with invalid values.
    public func write() throws(AWSConfigINIError) -> String {
        try canonicalWrite(self)
    }

    /// Writes the document to `url` using UTF-8 encoding, atomically.
    ///
    /// Atomic-replace only. For concurrent-write safety (the app and CLI both
    /// touching the same file), use the locked entrypoint
    /// ``update(at:flavor:options:mode:_:)`` instead.
    ///
    /// - Parameters:
    ///   - url: The destination file URL.
    ///   - mode: Operating mode. `.readOnly` throws ``AWSConfigINIError/readOnly(_:)``
    ///     immediately with no side effects. `.managed` (default) prepends the
    ///     managed-mode header comment on the first write, then serializes atomically.
    ///
    /// - Note: The caller's preference (managed vs. read-only) is stored outside this
    ///   module — in the app/CLI shared Keychain under access group
    ///   `$(AppIdentifierPrefix)dev.ajbeck.quorra.shared`, key
    ///   `(service: "dev.ajbeck.quorra.settings", account: "aws-files-mode")`.
    ///   Both the app and the CLI read that item and pass the resolved `ManagedMode`
    ///   to this parameter on every write. See CLAUDE.md "App ↔ CLI Architecture".
    ///   TODO: wire Keychain read at app/CLI call sites (tracked in plan §14.2 task 6).
    ///
    /// - Throws:
    ///   - `AWSConfigINIError.readOnly(url)` if `mode == .readOnly`.
    ///   - `AWSConfigINIError.encodeError` if any value cannot be encoded (see `write()`).
    ///   - `AWSConfigINIError.ioError` if the write fails.
    public func write(to url: URL, mode: ManagedMode = .managed, options: AWSConfigINIDocumentOptions = .default) throws(AWSConfigINIError) {
        guard mode != .readOnly else {
            throw .readOnly(url)
        }
        // Ensure the managed-mode header is present before serializing.
        // Work on a local copy so `self` remains unchanged if an encode error occurs.
        var copy = self
        ensureManagedHeader(in: &copy, options: options)
        let data = try copy.serializeToData()
        try writeAtomically(data: data, to: url)
    }

    /// Serializes the document to its on-disk byte representation, including
    /// the UTF-8 content plus any UTF-16 BOM prefix.
    ///
    /// `write() -> String` already emits U+FEFF for UTF-8 BOMs (which UTF-8-encodes
    /// to `EF BB BF`), but UTF-16 BOM bytes (`FF FE` / `FE FF`) cannot live inside
    /// a UTF-8 string and must be prepended at the byte layer here.
    private func serializeToData() throws(AWSConfigINIError) -> Data {
        let text = try write()
        guard let contentData = text.data(using: .utf8) else {
            throw .malformedInput("Document cannot be encoded as UTF-8")
        }
        if let bom = bomKind, bom != .utf8 {
            return Data(bom.bytes) + contentData
        }
        return contentData
    }

    // MARK: - Locked read-modify-write (M05)

    /// Acquires an exclusive fcntl advisory lock on `<url>.lock`, reads the
    /// current file contents (treating a missing file as an empty document of
    /// `flavor`), passes the parsed document to `block` for mutation, then
    /// serializes and atomically writes the result back to `url`.
    ///
    /// This is the primary write entrypoint for the app and the CLI. Both
    /// binaries call `update(at:flavor:options:mode:_:)` and cooperate via the
    /// shared sibling lock file. CLAUDE.md "App ↔ CLI Architecture": treat the
    /// filesystem as shared mutable state; use file locks for concurrent safety.
    ///
    /// Plan §11.2 task 4; Decision D08 (fcntl advisory lock).
    ///
    /// > Important: The fcntl advisory lock is *per-process*, not per-thread.
    /// > It serializes calls **between processes** (e.g. the app and the CLI)
    /// > but does NOT serialize concurrent calls from multiple threads or
    /// > Tasks within the same process. Same-process callers must add their
    /// > own mutual exclusion (e.g. an `actor`, `NSLock`, or `DispatchSemaphore`)
    /// > if `update(at:_:)` is reachable from more than one thread at once.
    /// >
    /// > This method is also synchronous and uses `Thread.sleep` while polling
    /// > for the lock. Callers running on a Swift Concurrency executor should
    /// > wrap with `Task.detached { ... }` so the cooperative scheduler isn't
    /// > blocked.
    ///
    /// - Parameters:
    ///   - url: The data file URL (e.g. `~/.aws/config`).
    ///   - flavor: Passed to the empty-document fallback if the file is absent.
    ///   - options: Parse/write options; defaults to `.default`.
    ///   - mode: Operating mode. `.readOnly` throws ``AWSConfigINIError/readOnly(_:)``
    ///     **before** acquiring the lock or reading the file — fail-fast, no side effects.
    ///     `.managed` (default) acquires the lock, reads, hands to `block`, prepends the
    ///     managed-mode header comment if absent, then atomically writes.
    ///
    ///   - Note: The caller's preference (managed vs. read-only) is stored outside this
    ///     module — in the app/CLI shared Keychain under access group
    ///     `$(AppIdentifierPrefix)dev.ajbeck.quorra.shared`, key
    ///     `(service: "dev.ajbeck.quorra.settings", account: "aws-files-mode")`.
    ///     Both the app and the CLI read that item and pass the resolved `ManagedMode`
    ///     to this parameter on every write. See CLAUDE.md "App ↔ CLI Architecture".
    ///     TODO: wire Keychain read at app/CLI call sites (tracked in plan §14.2 task 6).
    ///
    ///   - block: Receives the parsed (or empty) document `inout`; mutate as
    ///     needed. May throw an `AWSConfigINIError`; the error propagates.
    /// - Throws:
    ///   - `AWSConfigINIError.readOnly(url)` if `mode == .readOnly` (thrown before lock acquisition).
    ///   - `AWSConfigINIError.lockTimeout(url)` if the lock cannot be acquired within 5 seconds.
    ///   - `AWSConfigINIError.ioError` for other IO failures.
    ///   - `AWSConfigINIError.encodeError` if a key value is unrepresentable.
    ///   - Any error thrown by `block`.
    public static func update(
        at url: URL,
        flavor: FileFlavor,
        options: AWSConfigINIDocumentOptions = .default,
        mode: ManagedMode = .managed,
        _ block: (inout AWSConfigINIDocument) throws(AWSConfigINIError) -> Void
    ) throws(AWSConfigINIError) {
        // Fail-fast for read-only mode — before lock acquisition, before any IO.
        guard mode != .readOnly else {
            throw .readOnly(url)
        }

        try FileLock.exclusive(on: url) { () throws(AWSConfigINIError) in
            // Read current contents; file-not-found → empty document of given flavor.
            // `init(contentsOf:)` uses untyped throws (Swift 6.2 SIL-crash workaround,
            // see its docstring), so map back to typed throws here.
            var doc: AWSConfigINIDocument
            do {
                doc = try AWSConfigINIDocument(contentsOf: url, flavor: flavor, options: options)
            } catch let e as AWSConfigINIError {
                if case .fileNotFound = e {
                    doc = AWSConfigINIDocument(empty: flavor)
                } else {
                    throw e
                }
            } catch {
                throw .ioError(url, underlying: error)
            }

            try block(&doc)

            // Ensure the managed-mode header is present after the block runs, before serializing.
            ensureManagedHeader(in: &doc, options: options)

            try writeAtomically(data: try doc.serializeToData(), to: url)
        }
    }

    // MARK: - Private helpers

    private static func convertValue(_ v: ParsedValue) -> Value {
        switch v {
        case .string(let s): return .string(s)
        case .map(let m): return .map(m)
        }
    }

    private static func detectLineEnding(in string: String) -> String {
        string.contains("\r\n") ? "\r\n" : "\n"
    }
}
