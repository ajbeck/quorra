// KeyEncodingStrategy / KeyDecodingStrategy — key transformation strategies for
// AWSConfigINIEncoder and AWSConfigINIDecoder.
//
// Default strategy for encoding:  .convertToSnakeCase  (Swift camelCase → AWS snake_case)
// Default strategy for decoding:  .convertFromSnakeCase (AWS snake_case → Swift camelCase)
//
// Plan §12.2 task 1; marshal spec §6.6 "NameMapper" row.
// Decision D10: lean Codable surface with snake_case as the AWS default.

import Foundation

/// Strategy for translating Swift `CodingKey` values to INI key names on encode.
///
/// Default is `.convertToSnakeCase` because AWS files use `snake_case` universally.
/// Marshal spec §6.6; plan §12.2 task 1.
public enum KeyEncodingStrategy: Sendable {
    /// Use the coding key's `stringValue` without transformation.
    case useDefaultKeys

    /// Convert camelCase coding key names to `snake_case`.
    ///
    /// Algorithm (matches `JSONEncoder.KeyEncodingStrategy.convertToSnakeCase`):
    /// insert `_` before each upper-case letter that follows a lower-case letter
    /// or digit, then lowercase the result.
    /// Examples: `ssoSession` → `sso_session`, `region` → `region`.
    case convertToSnakeCase

    /// Apply a custom closure to each coding key.
    ///
    /// The closure receives the original `CodingKey` and returns the INI key string to use.
    /// The returned string is lowercased by the encoder per parser spec §7.1.
    case custom(@Sendable (CodingKey) -> String)
}

/// Strategy for translating INI key names to Swift `CodingKey` values on decode.
///
/// Default is `.convertFromSnakeCase` because AWS files use `snake_case` universally.
/// Marshal spec §6.6; plan §12.2 task 1.
public enum KeyDecodingStrategy: Sendable {
    /// Use the INI key name without transformation.
    case useDefaultKeys

    /// Convert `snake_case` INI key names to camelCase for Swift field lookup.
    ///
    /// Algorithm (mirrors `JSONDecoder.KeyDecodingStrategy.convertFromSnakeCase`):
    /// split on `_`, capitalize each subsequent word, join.
    /// Examples: `sso_session` → `ssoSession`, `region` → `region`.
    case convertFromSnakeCase

    /// Apply a custom closure to each INI key name, returning the `CodingKey` to use.
    case custom(@Sendable (String) -> CodingKey)
}

// MARK: - Internal application helpers

/// Applies `KeyEncodingStrategy` to a `CodingKey`, returning the lowercase INI key string.
///
/// The result is always lowercased per parser spec §7.1 (keys are stored lowercased).
func applyEncodingStrategy(_ strategy: KeyEncodingStrategy, to key: CodingKey) -> String {
    let raw: String
    switch strategy {
    case .useDefaultKeys:
        raw = key.stringValue
    case .convertToSnakeCase:
        raw = camelToSnake(key.stringValue)
    case .custom(let fn):
        raw = fn(key)
    }
    return raw.lowercased()
}

/// Applies `KeyDecodingStrategy` to an INI key name, returning the camelCase string
/// used to match the Swift `CodingKey` by its `stringValue`.
///
/// The decoder uses this to map `sso_session` (INI) → `ssoSession` (Swift field).
func applyDecodingStrategy(_ strategy: KeyDecodingStrategy, to iniKey: String) -> String {
    switch strategy {
    case .useDefaultKeys:
        return iniKey
    case .convertFromSnakeCase:
        return snakeToCamel(iniKey)
    case .custom(let fn):
        return fn(iniKey).stringValue
    }
}

// MARK: - Conversion algorithms

/// camelCase → snake_case.
///
/// Inserts `_` before each uppercase letter that is preceded by a lowercase letter or digit,
/// then lowercases the whole string.
/// Examples: `ssoSession` → `sso_session`, `credentialProcess` → `credential_process`.
func camelToSnake(_ s: String) -> String {
    guard !s.isEmpty else { return s }
    var result = ""
    result.reserveCapacity(s.count + 4)
    let scalars = s.unicodeScalars
    var prev: Unicode.Scalar? = nil
    for scalar in scalars {
        if let p = prev,
           CharacterSet.lowercaseLetters.union(.decimalDigits).contains(p),
           CharacterSet.uppercaseLetters.contains(scalar) {
            result.append("_")
        }
        result.append(Character(scalar))
        prev = scalar
    }
    return result.lowercased()
}

/// snake_case → camelCase.
///
/// Splits on `_`, capitalizes each subsequent component's first letter, joins.
/// Examples: `sso_session` → `ssoSession`, `region` → `region`.
func snakeToCamel(_ s: String) -> String {
    let parts = s.split(separator: "_", omittingEmptySubsequences: false)
    guard !parts.isEmpty else { return s }
    var result = String(parts[0])
    for part in parts.dropFirst() {
        if let first = part.first {
            result += first.uppercased() + part.dropFirst()
        }
    }
    return result
}
