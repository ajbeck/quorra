// Section — a named bag of Keys within an AWSConfigINIDocument.
//
// Internal storage uses an ordered [Key] array plus a [String: Int] name-index
// for O(1) lookup by lowercased key name. The index is rebuilt when needed.
// Plan §4.2, §5.

/// A named section in an AWS INI document.
///
/// Section names are case-sensitive and stored verbatim from the file
/// (with only inner whitespace trimmed and type/name collapsed to one space).
/// Parser spec §6.2
public struct Section: Sendable {
    /// The full section name as it appears in the file, e.g. `"profile foo"` or `"default"`.
    public let name: String

    /// Leading comment lines associated with this section header.
    /// Each element is a raw comment string including the `#` or `;` prefix.
    public var leadingComments: [String]

    /// Parse-time warnings for this section (duplicate keys, unrecognized lines, etc.).
    /// Decision D06 — silent tolerances with opt-in warnings.
    public var warnings: [Warning]

    // MARK: Internal storage

    /// Ordered key list. Preserves insertion order.
    var _keys: [Key]

    /// Name-to-index map for O(1) lookup. Always in sync with _keys.
    var _keyIndex: [String: Int]

    // MARK: Init

    init(name: String, leadingComments: [String] = [], warnings: [Warning] = [], keys: [Key] = []) {
        self.name = name
        self.leadingComments = leadingComments
        self.warnings = warnings
        self._keys = keys
        self._keyIndex = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1.name, $0) })
    }

    // MARK: - Public API

    /// The ordered keys in this section.
    public var keys: [Key] { _keys }

    /// Returns the key with the given name (case-insensitive lookup via stored lowercase).
    /// Returns `nil` if the key is absent.
    ///
    /// Mirrors: Section.Has / Section.String etc. in sections.go
    public func key(_ name: String) -> Key? {
        guard let idx = _keyIndex[name.lowercased()] else { return nil }
        return _keys[idx]
    }

    // MARK: - Mutations (M04 surface — stubs with implementations for round-trip use in M01 tests)

    /// Sets the string value of `name`. If the key exists, its value is updated and
    /// leading comments are preserved. If absent, a new key is appended.
    public mutating func setKey(_ name: String, value: String) {
        let lc = name.lowercased()
        if let idx = _keyIndex[lc] {
            _keys[idx] = Key(name: lc, value: .string(value), leadingComments: _keys[idx].leadingComments)
        } else {
            _keyIndex[lc] = _keys.count
            _keys.append(Key(name: lc, value: .string(value)))
        }
    }

    /// Sets the map value of `name`.
    public mutating func setKey(_ name: String, map: [String: String]) {
        let lc = name.lowercased()
        if let idx = _keyIndex[lc] {
            _keys[idx] = Key(name: lc, value: .map(map), leadingComments: _keys[idx].leadingComments)
        } else {
            _keyIndex[lc] = _keys.count
            _keys.append(Key(name: lc, value: .map(map)))
        }
    }

    /// Removes the key with the given name. No-op if absent.
    public mutating func deleteKey(_ name: String) {
        let lc = name.lowercased()
        guard let idx = _keyIndex.removeValue(forKey: lc) else { return }
        _keys.remove(at: idx)
        // Decrement every index that pointed past the removed slot.
        // O(n) over the index map vs. an O(n) full rebuild — same complexity, ~half the work.
        for (k, v) in _keyIndex where v > idx {
            _keyIndex[k] = v - 1
        }
    }
}
