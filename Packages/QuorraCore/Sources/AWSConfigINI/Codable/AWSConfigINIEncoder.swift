// AWSConfigINIEncoder — encodes an Encodable value into a named section of an
// AWSConfigINIDocument using section-replace semantics.
//
// Section-replace semantics (Decision D05):
//   The encoder fully replaces the keys in the target section. Section-level comments
//   (leadingComments) survive because we create a fresh Section with the existing
//   section's leadingComments preserved. Per-key comments inside the old section are
//   dropped — this is the explicit D05 trade-off.
//
// Algorithm:
//   1. Encodable value's encode(to:) is called with _SectionEncoder.
//   2. _SectionEncoder accumulates a [String: Value] map (INI key → Value).
//   3. On finish, document.update(sectionName) replaces the section's keys entirely,
//      while preserving leadingComments from the existing section.
//   4. If the section does not yet exist, ensureSection creates it first.
//
// Type dispatch (plan §12.2 task 4; marshal spec §6.3 "Write" column):
//   String          → Value.string
//   Int* / UInt*    → Value.string(String(value))
//   Float / Double  → Value.string(String(value))
//   Bool            → Value.string("true") or "false"  [D11 strict on output]
//   [String: String]→ Value.map
//   [String]        → Value.string(joined with ", ")
//   nil Optional    → omitted when omitEmpty == true (default), or Value.string("") when false
//   Nested struct   → rejected with TODO for M07
//
// omitEmpty (default true):
//   nil Optional fields produce no key.
//   Non-Optional fields with zero/default values still emit (they're explicit in the model).
//   The asymmetry: Optional nil → omit; non-Optional default-zero → emit.
//   This matches go-ini's omitempty semantic (struct.go:596-598).
//
// Plan §12.2 task 4; Decision D05, D11.

import Foundation

// MARK: - Public API

/// Encodes `Encodable` values into a named section of an `AWSConfigINIDocument`.
///
/// Section-replace semantics: encoding a value into a section that already has keys
/// replaces all keys with the encoded output. Section leading comments are preserved;
/// per-key comments in the old section are dropped (Decision D05).
///
/// Usage:
/// ```swift
/// var doc = try AWSConfigINIDocument(contentsOf: url)
/// let encoder = AWSConfigINIEncoder()
/// try encoder.encode(myProfile, into: &doc, section: "profile dev")
/// try doc.write(to: url)
/// ```
///
/// Plan §12.2 task 4; marshal spec §6.5.
public struct AWSConfigINIEncoder: Sendable {
    /// Strategy for mapping Swift `CodingKey` values to INI key names.
    /// Default `.convertToSnakeCase` handles the `camelCase` → `snake_case` AWS mapping.
    public var keyEncodingStrategy: KeyEncodingStrategy = .convertToSnakeCase

    /// When `true` (default), `nil` Optional fields produce no key in the output.
    /// When `false`, `nil` Optionals produce an empty-string key (`key = ""`).
    ///
    /// Non-Optional fields with default-zero values always emit regardless of this setting.
    /// The asymmetry mirrors go-ini's `omitempty` tag behavior (struct.go:596-598).
    public var omitEmpty: Bool = true

    public init() {}

    /// Encodes `value` into the profile named `named` inside `doc`.
    ///
    /// Resolves the correct section name via `doc.flavor.profileSectionName(for: named)`,
    /// then delegates to `encode(_:into:section:)` with section-replace semantics.
    ///
    /// - Parameters:
    ///   - value: The `Encodable` value to encode.
    ///   - named: The profile name (e.g. `"dev"`, `"default"`).
    ///   - doc: The document to encode into (modified in place; its `flavor` drives the projection).
    /// - Throws: `.encodeError` if an unsupported container type is requested.
    /// Plan §13.2 task 6; marshal spec §7.
    public func encodeProfile<T: Encodable>(
        _ value: T,
        named: String,
        into doc: inout AWSConfigINIDocument
    ) throws(AWSConfigINIError) {
        let sectionName = doc.flavor.profileSectionName(for: named)
        try encode(value, into: &doc, section: sectionName)
    }

    /// Encodes `value` into the section named `section` of `doc`.
    ///
    /// Performs section-replace: all existing keys in the section are replaced by the
    /// encoded output. The section's `leadingComments` survive; per-key comments are dropped.
    /// If the section does not exist, it is created.
    ///
    /// - Parameters:
    ///   - value: The `Encodable` value to encode.
    ///   - doc: The document to encode into (modified in place).
    ///   - section: The verbatim section name (e.g. `"profile dev"`, `"default"`).
    /// - Throws: `.encodeError` if an unsupported container type is requested
    ///   (e.g. nested struct, array of arrays).
    public func encode<T: Encodable>(
        _ value: T,
        into doc: inout AWSConfigINIDocument,
        section sectionName: String
    ) throws(AWSConfigINIError) {
        let enc = _SectionEncoder(
            keyEncodingStrategy: keyEncodingStrategy,
            omitEmpty: omitEmpty,
            codingPath: []
        )
        do {
            try value.encode(to: enc)
        } catch let e as AWSConfigINIError {
            throw e
        } catch {
            throw .encodeError("Encoding '\(T.self)' into section '\(sectionName)' failed: \(error)")
        }
        // Capture the accumulated key-value pairs.
        let collected = enc.storage.entries

        // Preserve existing section's leading comments (D05).
        let existingLeadingComments = doc.section(sectionName)?.leadingComments ?? []

        // Ensure the section exists, then replace all its keys.
        doc.ensureSection(sectionName)
        doc.update(sectionName) { section in
            // Section-replace: clear all existing keys, set leadingComments.
            // We build a fresh section with the preserved comments and new keys.
            section = Section(
                name: sectionName,
                leadingComments: existingLeadingComments,
                warnings: [],
                keys: []
            )
            // Insert keys in the order they were encoded.
            for (iniKeyName, value) in collected {
                switch value {
                case .string(let s):
                    section.setKey(iniKeyName, value: s)
                case .map(let m):
                    section.setKey(iniKeyName, map: m)
                }
            }
        }
    }
}

// MARK: - Collected entry storage

/// Holds the ordered list of (INI key name, Value) pairs collected during encoding.
///
/// Using a class (reference semantics) so that nested containers and the encoder
/// all write into the same backing store without having to thread return values.
///
/// `@unchecked Sendable` rationale: each `encode(_:into:section:)` call constructs
/// its own `_EncoderStorage` instance and threads it through the `_SectionEncoder`
/// and its containers synchronously on a single thread. The instance is discarded
/// before `encode(_:into:section:)` returns. No cross-thread mutation is possible
/// because the storage is never published outside the call's own stack. Adding a
/// lock would be pure overhead. If a future change ever causes an encode pass to
/// fan out across threads (it shouldn't), revisit this.
private final class _EncoderStorage: @unchecked Sendable {
    /// Ordered key-value pairs. Order matches the struct's Encodable key emission order.
    var entries: [(String, Value)] = []

    func append(key: String, value: Value) {
        // Replace if key already exists (section-replace handles this at the section level,
        // but within a single encode pass, last-writer-wins for duplicate keys).
        if let idx = entries.firstIndex(where: { $0.0 == key }) {
            entries[idx] = (key, value)
        } else {
            entries.append((key, value))
        }
    }
}

// MARK: - _SectionEncoder

/// Top-level `Encoder` implementation. Hands out a single keyed container that
/// collects key-value pairs into `storage`.
private final class _SectionEncoder: Encoder {
    let keyEncodingStrategy: KeyEncodingStrategy
    let omitEmpty: Bool
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]
    let storage: _EncoderStorage

    init(keyEncodingStrategy: KeyEncodingStrategy, omitEmpty: Bool, codingPath: [CodingKey]) {
        self.keyEncodingStrategy = keyEncodingStrategy
        self.omitEmpty = omitEmpty
        self.codingPath = codingPath
        self.storage = _EncoderStorage()
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        let c = _KeyedEncodingContainer<Key>(
            storage: storage,
            keyEncodingStrategy: keyEncodingStrategy,
            omitEmpty: omitEmpty,
            codingPath: codingPath
        )
        return KeyedEncodingContainer(c)
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        // Top-level unkeyed container is not meaningful for INI.
        // Return a container that will throw on first use.
        return _ErrorUnkeyedEncodingContainer(
            codingPath: codingPath,
            message: "INI sections cannot be encoded as a top-level array."
        )
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        return _ErrorSingleValueContainer(
            codingPath: codingPath,
            message: "INI sections cannot be encoded as a single scalar value."
        )
    }
}

// MARK: - _KeyedEncodingContainer

/// Implements `KeyedEncodingContainerProtocol`. Translates Swift coding keys to
/// INI key names and collects encoded values into `storage`.
private struct _KeyedEncodingContainer<K: CodingKey>: KeyedEncodingContainerProtocol {
    typealias Key = K

    let storage: _EncoderStorage
    let keyEncodingStrategy: KeyEncodingStrategy
    let omitEmpty: Bool
    let codingPath: [CodingKey]

    private func iniKeyName(for codingKey: K) -> String {
        applyEncodingStrategy(keyEncodingStrategy, to: codingKey)
    }

    // MARK: - Scalar encode methods

    mutating func encodeNil(forKey key: K) throws {
        // nil Optional — omit when omitEmpty, else emit empty string.
        if !omitEmpty {
            storage.append(key: iniKeyName(for: key), value: .string(""))
        }
        // When omitEmpty (default), produce no key. marshal spec §6.6 "omitempty" row.
    }

    mutating func encode(_ value: Bool, forKey key: K) throws {
        // D11: strict output — always "true" or "false".
        storage.append(key: iniKeyName(for: key), value: .string(value ? "true" : "false"))
    }

    mutating func encode(_ value: String, forKey key: K) throws {
        storage.append(key: iniKeyName(for: key), value: .string(value))
    }

    mutating func encode(_ value: Double, forKey key: K) throws {
        storage.append(key: iniKeyName(for: key), value: .string(String(value)))
    }

    mutating func encode(_ value: Float, forKey key: K) throws {
        storage.append(key: iniKeyName(for: key), value: .string(String(value)))
    }

    mutating func encode(_ value: Int, forKey key: K) throws {
        storage.append(key: iniKeyName(for: key), value: .string(String(value)))
    }

    mutating func encode(_ value: Int8, forKey key: K) throws {
        storage.append(key: iniKeyName(for: key), value: .string(String(value)))
    }

    mutating func encode(_ value: Int16, forKey key: K) throws {
        storage.append(key: iniKeyName(for: key), value: .string(String(value)))
    }

    mutating func encode(_ value: Int32, forKey key: K) throws {
        storage.append(key: iniKeyName(for: key), value: .string(String(value)))
    }

    mutating func encode(_ value: Int64, forKey key: K) throws {
        storage.append(key: iniKeyName(for: key), value: .string(String(value)))
    }

    mutating func encode(_ value: UInt, forKey key: K) throws {
        storage.append(key: iniKeyName(for: key), value: .string(String(value)))
    }

    mutating func encode(_ value: UInt8, forKey key: K) throws {
        storage.append(key: iniKeyName(for: key), value: .string(String(value)))
    }

    mutating func encode(_ value: UInt16, forKey key: K) throws {
        storage.append(key: iniKeyName(for: key), value: .string(String(value)))
    }

    mutating func encode(_ value: UInt32, forKey key: K) throws {
        storage.append(key: iniKeyName(for: key), value: .string(String(value)))
    }

    mutating func encode(_ value: UInt64, forKey key: K) throws {
        storage.append(key: iniKeyName(for: key), value: .string(String(value)))
    }

    // MARK: - Generic Encodable dispatch

    mutating func encode<T: Encodable>(_ value: T, forKey key: K) throws {
        let iniKey = iniKeyName(for: key)

        // [String: String] → sub-property map (D12; marshal spec §6.6 "nested values" row)
        if let map = value as? [String: String] {
            storage.append(key: iniKey, value: .map(map))
            return
        }

        // [String] → comma-separated value (marshal spec §6.6 "delim" row)
        if let arr = value as? [String] {
            storage.append(key: iniKey, value: .string(arr.joined(separator: ", ")))
            return
        }

        // Nested Decodable struct — rejected in v1.
        // TODO(M07): implement nested struct → child section encoding for AWS overlay types.
        throw AWSConfigINIError.encodeError(
            "Cannot encode '\(key.stringValue)' as '\(T.self)': " +
            "nested Encodable structs are not supported in v1. " +
            "AWS overlay structs (Profile, SSOSession, ServicesEntry) will be added in M07."
        )
    }

    // MARK: - Nested containers

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: K) -> KeyedEncodingContainer<NestedKey> {
        // INI has no nested keyed containers within a key's value.
        // Return an error container. Plan §12.2 task 5.
        let c = _ErrorKeyedEncodingContainer<NestedKey>(
            codingPath: codingPath + [key],
            message: "Cannot encode '\(key.stringValue)' as a nested keyed container: nested structs are not supported in v1 (TODO M07)."
        )
        return KeyedEncodingContainer(c)
    }

    mutating func nestedUnkeyedContainer(forKey key: K) -> UnkeyedEncodingContainer {
        // For [String] the encode<T> dispatch handles it above.
        // This path is reached for arrays of non-String types or arrays of arrays.
        return _ErrorUnkeyedEncodingContainer(
            codingPath: codingPath + [key],
            message: "INI has no array-of-array syntax. Cannot encode '\(key.stringValue)' as a nested unkeyed container."
        )
    }

    mutating func superEncoder() -> Encoder {
        return _SectionEncoder(
            keyEncodingStrategy: keyEncodingStrategy,
            omitEmpty: omitEmpty,
            codingPath: codingPath
        )
    }

    mutating func superEncoder(forKey key: K) -> Encoder {
        return _SectionEncoder(
            keyEncodingStrategy: keyEncodingStrategy,
            omitEmpty: omitEmpty,
            codingPath: codingPath + [key]
        )
    }
}

// MARK: - Error stub containers

/// A keyed encoding container that throws an error on any encode attempt.
/// Used when a nested keyed container is requested but not supported.
private struct _ErrorKeyedEncodingContainer<K: CodingKey>: KeyedEncodingContainerProtocol {
    typealias Key = K
    let codingPath: [CodingKey]
    let message: String

    private func fail() throws {
        throw AWSConfigINIError.encodeError(message)
    }

    mutating func encodeNil(forKey key: K) throws { try fail() }
    mutating func encode(_ value: Bool, forKey key: K) throws { try fail() }
    mutating func encode(_ value: String, forKey key: K) throws { try fail() }
    mutating func encode(_ value: Double, forKey key: K) throws { try fail() }
    mutating func encode(_ value: Float, forKey key: K) throws { try fail() }
    mutating func encode(_ value: Int, forKey key: K) throws { try fail() }
    mutating func encode(_ value: Int8, forKey key: K) throws { try fail() }
    mutating func encode(_ value: Int16, forKey key: K) throws { try fail() }
    mutating func encode(_ value: Int32, forKey key: K) throws { try fail() }
    mutating func encode(_ value: Int64, forKey key: K) throws { try fail() }
    mutating func encode(_ value: UInt, forKey key: K) throws { try fail() }
    mutating func encode(_ value: UInt8, forKey key: K) throws { try fail() }
    mutating func encode(_ value: UInt16, forKey key: K) throws { try fail() }
    mutating func encode(_ value: UInt32, forKey key: K) throws { try fail() }
    mutating func encode(_ value: UInt64, forKey key: K) throws { try fail() }
    mutating func encode<T: Encodable>(_ value: T, forKey key: K) throws { try fail() }
    mutating func nestedContainer<NK: CodingKey>(keyedBy type: NK.Type, forKey key: K) -> KeyedEncodingContainer<NK> {
        KeyedEncodingContainer(_ErrorKeyedEncodingContainer<NK>(codingPath: codingPath + [key], message: message))
    }
    mutating func nestedUnkeyedContainer(forKey key: K) -> UnkeyedEncodingContainer {
        _ErrorUnkeyedEncodingContainer(codingPath: codingPath + [key], message: message)
    }
    mutating func superEncoder() -> Encoder {
        _SectionEncoder(keyEncodingStrategy: .useDefaultKeys, omitEmpty: true, codingPath: codingPath)
    }
    mutating func superEncoder(forKey key: K) -> Encoder {
        _SectionEncoder(keyEncodingStrategy: .useDefaultKeys, omitEmpty: true, codingPath: codingPath + [key])
    }
}

/// An unkeyed encoding container that throws an error on first use.
private struct _ErrorUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let codingPath: [CodingKey]
    let message: String
    var count: Int = 0

    private func fail() throws {
        throw AWSConfigINIError.encodeError(message)
    }

    mutating func encodeNil() throws { try fail() }
    mutating func encode(_ value: Bool) throws { try fail() }
    mutating func encode(_ value: String) throws { try fail() }
    mutating func encode(_ value: Double) throws { try fail() }
    mutating func encode(_ value: Float) throws { try fail() }
    mutating func encode(_ value: Int) throws { try fail() }
    mutating func encode(_ value: Int8) throws { try fail() }
    mutating func encode(_ value: Int16) throws { try fail() }
    mutating func encode(_ value: Int32) throws { try fail() }
    mutating func encode(_ value: Int64) throws { try fail() }
    mutating func encode(_ value: UInt) throws { try fail() }
    mutating func encode(_ value: UInt8) throws { try fail() }
    mutating func encode(_ value: UInt16) throws { try fail() }
    mutating func encode(_ value: UInt32) throws { try fail() }
    mutating func encode(_ value: UInt64) throws { try fail() }
    mutating func encode<T: Encodable>(_ value: T) throws { try fail() }
    mutating func nestedContainer<NK: CodingKey>(keyedBy type: NK.Type) -> KeyedEncodingContainer<NK> {
        KeyedEncodingContainer(_ErrorKeyedEncodingContainer<NK>(codingPath: codingPath, message: message))
    }
    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        _ErrorUnkeyedEncodingContainer(codingPath: codingPath, message: message)
    }
    mutating func superEncoder() -> Encoder {
        _SectionEncoder(keyEncodingStrategy: .useDefaultKeys, omitEmpty: true, codingPath: codingPath)
    }
}

/// A single-value encoding container that throws an error on first use.
private struct _ErrorSingleValueContainer: SingleValueEncodingContainer {
    let codingPath: [CodingKey]
    let message: String

    private func fail() throws {
        throw AWSConfigINIError.encodeError(message)
    }

    mutating func encodeNil() throws { try fail() }
    mutating func encode(_ value: Bool) throws { try fail() }
    mutating func encode(_ value: String) throws { try fail() }
    mutating func encode(_ value: Double) throws { try fail() }
    mutating func encode(_ value: Float) throws { try fail() }
    mutating func encode(_ value: Int) throws { try fail() }
    mutating func encode(_ value: Int8) throws { try fail() }
    mutating func encode(_ value: Int16) throws { try fail() }
    mutating func encode(_ value: Int32) throws { try fail() }
    mutating func encode(_ value: Int64) throws { try fail() }
    mutating func encode(_ value: UInt) throws { try fail() }
    mutating func encode(_ value: UInt8) throws { try fail() }
    mutating func encode(_ value: UInt16) throws { try fail() }
    mutating func encode(_ value: UInt32) throws { try fail() }
    mutating func encode(_ value: UInt64) throws { try fail() }
    mutating func encode<T: Encodable>(_ value: T) throws { try fail() }
}
