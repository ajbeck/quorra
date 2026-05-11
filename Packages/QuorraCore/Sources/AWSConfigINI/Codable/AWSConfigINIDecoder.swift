// AWSConfigINIDecoder — decodes a Decodable value from a named section of an
// AWSConfigINIDocument.
//
// Architecture:
//   The public AWSConfigINIDecoder is a configuration object (like JSONDecoder).
//   Actual decoding is driven by _SectionDecoder, which conforms to Swift's Decoder
//   protocol and backs onto a Section. The keyed container is _KeyedContainer<K>;
//   the single-value container is _SingleValueContainer; unkeyed containers reject
//   all array-of-array nesting.
//
// Type dispatch (plan §12.2 task 3; marshal spec §6.3):
//   String              → key.stringValue
//   Int / Int8 / …      → key.intValue() with overflow check
//   UInt / UInt8 / …    → key.intValue() reinterpreted as unsigned with range check
//   Float / Double      → key.doubleValue()
//   Bool                → parseBool(key.stringValue, leniency:)
//   [String: String]    → key.mapValue()
//   [String]            → key.stringValue split on "," trimmed
//   Optional<T>         → present only if key exists
//   Nested Decodable    → rejected in v1 with TODO for M07; plan §12.2 task 3
//
// Error policy:
//   Missing required (non-Optional) field → .decodeError("Missing required key '<name>'")
//   Type mismatch / coercion failure      → .decodeError("Cannot decode '<key>' as <type>: …")
//   Unsupported container type            → .decodeError("INI sections …")
//
// Plan §12.2 task 3; D20 (typed throws).

import Foundation

// MARK: - Public API

/// Decodes `Decodable` values from a named section of an `AWSConfigINIDocument`.
///
/// Usage:
/// ```swift
/// let decoder = AWSConfigINIDecoder()
/// let profile = try decoder.decode(MyProfile.self, from: doc, section: "profile dev")
/// ```
///
/// The decoder converts INI key names to Swift field names using `keyDecodingStrategy`
/// (default `.convertFromSnakeCase`) before matching `CodingKey` values.
/// Plan §12.2 task 3; marshal spec §6.5.
public struct AWSConfigINIDecoder: Sendable {
    /// Strategy for mapping INI key names to Swift `CodingKey` values.
    /// Default `.convertFromSnakeCase` handles the `snake_case` → `camelCase` AWS mapping.
    public var keyDecodingStrategy: KeyDecodingStrategy = .convertFromSnakeCase

    /// Controls how boolean strings are parsed.
    /// Default `.strict` matches the AWS Go SDK (only `"true"` / `"false"`).
    /// Decision D11; marshal spec §6.4.
    public var booleanLeniency: BooleanLeniency = .strict

    public init() {}

    /// Decodes a value of type `T` from the profile named `named` in `doc`.
    ///
    /// Resolves the correct section name via `doc.flavor.profileSectionName(for: named)`,
    /// then delegates to `decode(_:from:section:)`.
    ///
    /// - Parameters:
    ///   - type: The `Decodable` type to decode.
    ///   - named: The profile name (e.g. `"dev"`, `"default"`).
    ///   - doc: The source document (its `flavor` drives the section-name projection).
    /// - Throws: `.decodeError` if the section is missing, a required field is absent,
    ///   or a value cannot be coerced to the expected type.
    /// Plan §13.2 task 6; marshal spec §7.
    public func decodeProfile<T: Decodable>(
        _ type: T.Type,
        named: String,
        from doc: AWSConfigINIDocument
    ) throws(AWSConfigINIError) -> T {
        let sectionName = doc.flavor.profileSectionName(for: named)
        return try decode(type, from: doc, section: sectionName)
    }

    /// Decodes a value of type `T` from the section named `section` in `doc`.
    ///
    /// - Parameters:
    ///   - type: The `Decodable` type to decode.
    ///   - doc: The source document.
    ///   - section: The verbatim section name (e.g. `"profile dev"`, `"default"`).
    /// - Throws: `.decodeError` if the section is missing, a required field is absent,
    ///   or a value cannot be coerced to the expected type.
    public func decode<T: Decodable>(
        _ type: T.Type,
        from doc: AWSConfigINIDocument,
        section sectionName: String
    ) throws(AWSConfigINIError) -> T {
        guard let section = doc.section(sectionName) else {
            throw .decodeError("Section '\(sectionName)' not found in document")
        }
        let decoder = _SectionDecoder(
            section: section,
            keyDecodingStrategy: keyDecodingStrategy,
            booleanLeniency: booleanLeniency,
            codingPath: []
        )
        do {
            return try T(from: decoder)
        } catch let e as AWSConfigINIError {
            throw e
        } catch {
            throw .decodeError("Decoding '\(T.self)' from section '\(sectionName)' failed: \(error)")
        }
    }
}

// MARK: - Internal _SectionDecoder

/// Conforms to `Decoder`. Backed by a `Section` from an `AWSConfigINIDocument`.
///
/// The Decoder protocol requires returning containers. INI sections are flat key-value stores;
/// the only sensible container is a keyed container. Single-value and unkeyed containers
/// at the top level are rejected unless they correspond to a direct scalar decode (which
/// the Codable machinery routes through keyed containers for struct types anyway).
private struct _SectionDecoder: Decoder {
    let section: Section
    let keyDecodingStrategy: KeyDecodingStrategy
    let booleanLeniency: BooleanLeniency
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        let c = _KeyedContainer<Key>(
            section: section,
            keyDecodingStrategy: keyDecodingStrategy,
            booleanLeniency: booleanLeniency,
            codingPath: codingPath
        )
        return KeyedDecodingContainer(c)
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        // An INI section is not an array at the top level.
        // Unkeyed containers at the section level are only reached when a
        // Decodable type calls unkeyedContainer() on the root decoder — not when
        // a keyed container field contains an array (that goes through
        // _KeyedContainer.nestedUnkeyedContainer which handles the [String] case).
        throw AWSConfigINIError.decodeError(
            "INI sections cannot be decoded as an unkeyed (array) container at the top level. " +
            "Use a struct conforming to Decodable."
        )
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        // Top-level single-value decode is unusual for struct types but must be
        // handled for completeness (e.g. if a caller does decode(String.self, ...)).
        // Return a container that delegates to the section's first key, which is
        // almost never the right thing — callers wanting a scalar should use a struct.
        // This is a best-effort path; the common path is keyed containers.
        throw AWSConfigINIError.decodeError(
            "INI sections cannot be decoded as a single scalar value at the top level. " +
            "Use a struct conforming to Decodable."
        )
    }
}

// MARK: - _KeyedContainer

/// Implements `KeyedDecodingContainerProtocol` backed by a `Section`.
///
/// Key lookup strategy:
/// 1. Apply `keyDecodingStrategy` to convert the Swift `CodingKey.stringValue` to the
///    expected INI key form (e.g. `ssoSession` → `sso_session`).
/// 2. Look up the result in `section.key(name)` (case-insensitive, already lowercase).
///
/// Wait — the strategy maps INI → Swift on decode. So we go the other way:
/// For each Swift CodingKey we want to find, we need the corresponding INI key name.
/// With `.convertFromSnakeCase` default:
///   Swift field `ssoSession` → we need to find INI key `sso_session`.
///   The strategy tells us `sso_session` → `ssoSession`, so we need to find
///   the INI key whose converted form matches our Swift key's stringValue.
///
/// Implementation: build a reverse map at init time from converted-INI-key → INI-key,
/// then use it for lookup. This is O(n) at init and O(1) per lookup.
private struct _KeyedContainer<K: CodingKey>: KeyedDecodingContainerProtocol {
    typealias Key = K

    let section: Section
    let keyDecodingStrategy: KeyDecodingStrategy
    let booleanLeniency: BooleanLeniency
    let codingPath: [CodingKey]

    /// Maps the "decoded" (strategy-applied) key name → the actual INI Key object.
    /// Built once at init from all keys in the section.
    private let decodedKeyMap: [String: AWSConfigINI.Key]

    init(
        section: Section,
        keyDecodingStrategy: KeyDecodingStrategy,
        booleanLeniency: BooleanLeniency,
        codingPath: [CodingKey]
    ) {
        self.section = section
        self.keyDecodingStrategy = keyDecodingStrategy
        self.booleanLeniency = booleanLeniency
        self.codingPath = codingPath
        // Build decoded-name → Key map.
        // Each INI key name (already lowercased) is passed through the decoding strategy
        // to yield the camelCase name that Codable will look up.
        var map: [String: AWSConfigINI.Key] = [:]
        for key in section.keys {
            let decoded = applyDecodingStrategy(keyDecodingStrategy, to: key.name)
            map[decoded] = key
        }
        self.decodedKeyMap = map
    }

    var allKeys: [K] {
        // Return CodingKeys for all decoded names that can be represented as K.
        decodedKeyMap.keys.compactMap { K(stringValue: $0) }
    }

    func contains(_ key: K) -> Bool {
        decodedKeyMap[key.stringValue] != nil
    }

    // MARK: - Core lookup

    /// Finds the INI `Key` matching the given Swift coding key.
    /// Returns `nil` if absent.
    private func iniKey(for codingKey: K) -> AWSConfigINI.Key? {
        decodedKeyMap[codingKey.stringValue]
    }

    // MARK: - Scalar decode methods

    func decodeNil(forKey key: K) throws -> Bool {
        // In INI there is no explicit nil; a key is nil iff it's absent.
        return iniKey(for: key) == nil
    }

    func decode(_ type: Bool.Type, forKey key: K) throws -> Bool {
        let k = try requireKey(key)
        guard let value = parseBool(k.stringValue, leniency: booleanLeniency) else {
            throw AWSConfigINIError.decodeError(
                "Cannot decode '\(key.stringValue)' as Bool: " +
                "'\(k.stringValue)' is not a valid boolean" +
                (booleanLeniency == .strict ? " (strict mode: only 'true'/'false')" : "")
            )
        }
        return value
    }

    func decode(_ type: String.Type, forKey key: K) throws -> String {
        let k = try requireKey(key)
        return k.stringValue
    }

    func decode(_ type: Double.Type, forKey key: K) throws -> Double {
        let k = try requireKey(key)
        guard let v = k.doubleValue() else {
            throw AWSConfigINIError.decodeError(
                "Cannot decode '\(key.stringValue)' as Double: '\(k.stringValue)' is not a valid floating-point number"
            )
        }
        return v
    }

    func decode(_ type: Float.Type, forKey key: K) throws -> Float {
        let d = try decode(Double.self, forKey: key)
        return Float(d)
    }

    func decode(_ type: Int.Type, forKey key: K) throws -> Int {
        Int(try decodeInt64(key: key))
    }

    func decode(_ type: Int8.Type, forKey key: K) throws -> Int8 {
        let v = try decodeInt64(key: key)
        guard let r = Int8(exactly: v) else {
            throw AWSConfigINIError.decodeError("Cannot decode '\(key.stringValue)' as Int8: value \(v) overflows")
        }
        return r
    }

    func decode(_ type: Int16.Type, forKey key: K) throws -> Int16 {
        let v = try decodeInt64(key: key)
        guard let r = Int16(exactly: v) else {
            throw AWSConfigINIError.decodeError("Cannot decode '\(key.stringValue)' as Int16: value \(v) overflows")
        }
        return r
    }

    func decode(_ type: Int32.Type, forKey key: K) throws -> Int32 {
        let v = try decodeInt64(key: key)
        guard let r = Int32(exactly: v) else {
            throw AWSConfigINIError.decodeError("Cannot decode '\(key.stringValue)' as Int32: value \(v) overflows")
        }
        return r
    }

    func decode(_ type: Int64.Type, forKey key: K) throws -> Int64 {
        try decodeInt64(key: key)
    }

    func decode(_ type: UInt.Type, forKey key: K) throws -> UInt {
        let v = try decodeInt64(key: key)
        guard let r = UInt(exactly: v) else {
            throw AWSConfigINIError.decodeError("Cannot decode '\(key.stringValue)' as UInt: value \(v) out of range")
        }
        return r
    }

    func decode(_ type: UInt8.Type, forKey key: K) throws -> UInt8 {
        let v = try decodeInt64(key: key)
        guard let r = UInt8(exactly: v) else {
            throw AWSConfigINIError.decodeError("Cannot decode '\(key.stringValue)' as UInt8: value \(v) out of range")
        }
        return r
    }

    func decode(_ type: UInt16.Type, forKey key: K) throws -> UInt16 {
        let v = try decodeInt64(key: key)
        guard let r = UInt16(exactly: v) else {
            throw AWSConfigINIError.decodeError("Cannot decode '\(key.stringValue)' as UInt16: value \(v) out of range")
        }
        return r
    }

    func decode(_ type: UInt32.Type, forKey key: K) throws -> UInt32 {
        let v = try decodeInt64(key: key)
        guard let r = UInt32(exactly: v) else {
            throw AWSConfigINIError.decodeError("Cannot decode '\(key.stringValue)' as UInt32: value \(v) out of range")
        }
        return r
    }

    func decode(_ type: UInt64.Type, forKey key: K) throws -> UInt64 {
        let v = try decodeInt64(key: key)
        guard v >= 0 else {
            throw AWSConfigINIError.decodeError("Cannot decode '\(key.stringValue)' as UInt64: value \(v) is negative")
        }
        return UInt64(bitPattern: v)
    }

    // MARK: - Generic Decodable dispatch

    func decode<T: Decodable>(_ type: T.Type, forKey key: K) throws -> T {
        // [String: String] — sub-property map (marshal spec §6.6 "nested values" row)
        if type == [String: String].self {
            let k = try requireKey(key)
            guard let map = k.mapValue() else {
                // Key exists but is a string, not a map. Return empty map rather than error
                // because an empty string-valued key means the sub-property block was empty.
                if k.stringValue.isEmpty {
                    return ([:] as! T)
                }
                throw AWSConfigINIError.decodeError(
                    "Cannot decode '\(key.stringValue)' as [String: String]: key is a scalar string, not a sub-property map"
                )
            }
            return (map as! T)
        }

        // [String] — comma-separated list (plan §12.2 task 3; used for sso_registration_scopes)
        if type == [String].self {
            let k = try requireKey(key)
            let raw = k.stringValue
            if raw.isEmpty {
                return ([] as! T)
            }
            let items = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return (items as! T)
        }

        // Nested Decodable struct — rejected in v1. M07 will implement section-lookup
        // for the AWS overlay (Profile.ssoSession → [sso-session NAME] section).
        // TODO(M07): implement nested struct → child section lookup.
        throw AWSConfigINIError.decodeError(
            "Cannot decode '\(key.stringValue)' as '\(T.self)': " +
            "nested Decodable structs are not supported in v1. " +
            "AWS overlay structs (Profile, SSOSession, ServicesEntry) will be added in M07."
        )
    }

    // MARK: - Optional (superDecodeIfPresent paths)

    func decodeIfPresent(_ type: Bool.Type, forKey key: K) throws -> Bool? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: String.Type, forKey key: K) throws -> String? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: Double.Type, forKey key: K) throws -> Double? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: Float.Type, forKey key: K) throws -> Float? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: Int.Type, forKey key: K) throws -> Int? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: Int8.Type, forKey key: K) throws -> Int8? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: Int16.Type, forKey key: K) throws -> Int16? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: Int32.Type, forKey key: K) throws -> Int32? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: Int64.Type, forKey key: K) throws -> Int64? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: UInt.Type, forKey key: K) throws -> UInt? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: UInt8.Type, forKey key: K) throws -> UInt8? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: UInt16.Type, forKey key: K) throws -> UInt16? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: UInt32.Type, forKey key: K) throws -> UInt32? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent(_ type: UInt64.Type, forKey key: K) throws -> UInt64? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: K) throws -> T? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }

    // MARK: - Nested containers (not meaningful for flat INI sections)

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: K) throws -> KeyedDecodingContainer<NestedKey> {
        // INI has no nested keyed containers within a key's value.
        // This path is hit when a Decodable struct has a nested struct field that is
        // not [String: String] or [String]. Reject per plan §12.2 task 3 TODO.
        throw AWSConfigINIError.decodeError(
            "Cannot decode '\(key.stringValue)' as a nested keyed container: " +
            "nested Decodable structs are not supported in v1. " +
            "AWS overlay structs will be added in M07."
        )
    }

    func nestedUnkeyedContainer(forKey key: K) throws -> UnkeyedDecodingContainer {
        // This path is taken for [String] and [String: String] only if the Codable
        // machinery routes through an unkeyed container, which it does NOT for
        // Array<String> when we handle it in decode<T>(_:forKey:) above.
        // This is the fallback for other array element types (e.g. [Int]).
        // Provide a simple comma-split unkeyed container.
        let k = try requireKey(key)
        let raw = k.stringValue
        let items: [String] = raw.isEmpty ? [] : raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return _StringArrayUnkeyedContainer(elements: items, codingPath: codingPath + [key])
    }

    func superDecoder() throws -> Decoder {
        // Not meaningful for INI; return the section decoder at the same path.
        return _SectionDecoder(
            section: section,
            keyDecodingStrategy: keyDecodingStrategy,
            booleanLeniency: booleanLeniency,
            codingPath: codingPath
        )
    }

    func superDecoder(forKey key: K) throws -> Decoder {
        return _SectionDecoder(
            section: section,
            keyDecodingStrategy: keyDecodingStrategy,
            booleanLeniency: booleanLeniency,
            codingPath: codingPath + [key]
        )
    }

    // MARK: - Private helpers

    /// Returns the INI Key for `codingKey`, or throws `.decodeError` if absent.
    private func requireKey(_ codingKey: K) throws -> AWSConfigINI.Key {
        guard let k = iniKey(for: codingKey) else {
            throw AWSConfigINIError.decodeError("Missing required key '\(codingKey.stringValue)'")
        }
        return k
    }

    /// Common Int64 decode path used by all integer variants.
    private func decodeInt64(key: K) throws -> Int64 {
        let k = try requireKey(key)
        guard let v = k.intValue() else {
            throw AWSConfigINIError.decodeError(
                "Cannot decode '\(key.stringValue)' as integer: '\(k.stringValue)' is not a valid integer"
            )
        }
        return v
    }
}

// MARK: - _StringArrayUnkeyedContainer

/// An unkeyed container backed by a `[String]` from a comma-split INI value.
///
/// Used by `nestedUnkeyedContainer(forKey:)` so that Codable machinery that
/// routes arrays through unkeyed containers still works for `[String]`.
/// Arrays of non-String types (e.g. `[Int]`) are not supported — INI has no
/// typed array syntax.
private struct _StringArrayUnkeyedContainer: UnkeyedDecodingContainer {
    let elements: [String]
    let codingPath: [CodingKey]
    var currentIndex: Int = 0

    var count: Int? { elements.count }
    var isAtEnd: Bool { currentIndex >= elements.count }

    mutating func decodeNil() throws -> Bool {
        // String elements are never nil.
        return false
    }

    mutating func decode(_ type: String.Type) throws -> String {
        guard !isAtEnd else {
            throw AWSConfigINIError.decodeError("Unkeyed container is exhausted")
        }
        defer { currentIndex += 1 }
        return elements[currentIndex]
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if type == String.self {
            return try decode(String.self) as! T
        }
        throw AWSConfigINIError.decodeError(
            "INI comma-separated lists only support String elements; cannot decode '\(T.self)'"
        )
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        throw AWSConfigINIError.decodeError("INI has no array-of-object syntax")
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw AWSConfigINIError.decodeError("INI has no array-of-array syntax")
    }

    mutating func superDecoder() throws -> Decoder {
        throw AWSConfigINIError.decodeError("superDecoder() not supported in INI unkeyed container")
    }

    // Unused scalar types — all throw; INI lists are string-only.
    mutating func decode(_ type: Bool.Type) throws -> Bool { throw unsupportedElement("Bool") }
    mutating func decode(_ type: Double.Type) throws -> Double { throw unsupportedElement("Double") }
    mutating func decode(_ type: Float.Type) throws -> Float { throw unsupportedElement("Float") }
    mutating func decode(_ type: Int.Type) throws -> Int { throw unsupportedElement("Int") }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { throw unsupportedElement("Int8") }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { throw unsupportedElement("Int16") }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { throw unsupportedElement("Int32") }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { throw unsupportedElement("Int64") }
    mutating func decode(_ type: UInt.Type) throws -> UInt { throw unsupportedElement("UInt") }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { throw unsupportedElement("UInt8") }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { throw unsupportedElement("UInt16") }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { throw unsupportedElement("UInt32") }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { throw unsupportedElement("UInt64") }

    private func unsupportedElement(_ typeName: String) -> AWSConfigINIError {
        .decodeError("INI comma-separated lists only support String elements; cannot decode '\(typeName)'")
    }
}
