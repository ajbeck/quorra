// Shared test helpers for AWSConfigINITests.
//
// Centralizes fixture loading and expected-JSON utilities so multiple test files
// (FixtureParityTests, MutationTests, future M05+ FileIOTests, etc.) can share
// the same loaders without re-implementing them or `private`-scoping them per file.

import Foundation
import Testing
@testable import AWSConfigINI

/// Resolves a fixture file URL from `Resources/aws-sdk-fixtures/`.
/// Calls `fatalError` if the fixture is missing — vendored fixtures are committed,
/// a missing one is a real-time test-corpus regression.
func fixtureURL(_ name: String) -> URL {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources/aws-sdk-fixtures") else {
        fatalError("Missing fixture: \(name)")
    }
    return url
}

/// Loads a fixture file as a UTF-8 string.
func loadFixtureString(_ name: String) -> String {
    let url = fixtureURL(name)
    guard let s = try? String(contentsOf: url, encoding: .utf8) else {
        fatalError("Cannot load fixture: \(name)")
    }
    return s
}

/// Loads `<name>_expected` as `[sectionName: [key: valueString]]`.
/// Map-typed values are encoded as Go's `map[k:v k2:v2]` string per the AWS Go SDK fixtures.
func loadExpected(_ fixtureName: String) -> [String: [String: String]] {
    let url = fixtureURL("\(fixtureName)_expected")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else {
        fatalError("Cannot load or decode expected JSON: \(fixtureName)_expected")
    }
    return json
}

/// Parses a map-value description string like `map[a:b b:c]` into a `[String: String]`.
/// This is Go's `fmt.Sprintf("%v", m)` format used in the expected JSON files.
///
/// Heuristic: keys can't contain spaces or colons; values can contain colons but
/// not spaces. The fixture corpus is authored to satisfy this — see parser spec §14.
func parseGoMapString(_ s: String) -> [String: String]? {
    guard s.hasPrefix("map[") && s.hasSuffix("]") else { return nil }
    let inner = String(s.dropFirst(4).dropLast())
    guard !inner.isEmpty else { return [:] }
    var result: [String: String] = [:]
    var remaining = inner[inner.startIndex...]
    while !remaining.isEmpty {
        guard let colonRange = remaining.range(of: ":") else { break }
        let key = String(remaining[remaining.startIndex..<colonRange.lowerBound])
        remaining = remaining[colonRange.upperBound...]
        if let spaceIdx = remaining.firstIndex(of: " ") {
            let value = String(remaining[remaining.startIndex..<spaceIdx])
            result[key] = value
            remaining = remaining[remaining.index(after: spaceIdx)...]
        } else {
            result[key] = String(remaining)
            break
        }
    }
    return result
}

/// Asserts that `document` contains every section/key pair from `expected`.
/// Tolerates extra keys (the AWS SDK `_expected` JSONs are loose — see parser spec §14).
func assertMatchesExpected(
    document: AWSConfigINIDocument,
    expected: [String: [String: String]],
    fixture: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    for (sectionName, expectedKeys) in expected {
        guard let section = document.section(sectionName) else {
            Issue.record("[\(fixture)] Missing section '\(sectionName)'", sourceLocation: sourceLocation)
            continue
        }
        for (keyName, expectedValue) in expectedKeys {
            guard let key = section.key(keyName) else {
                Issue.record("[\(fixture)] Section '\(sectionName)' missing key '\(keyName)'", sourceLocation: sourceLocation)
                continue
            }
            if let mapDict = parseGoMapString(expectedValue) {
                guard let actualMap = key.mapValue() else {
                    Issue.record("[\(fixture)] '\(sectionName).\(keyName)': expected map but got string '\(key.stringValue)'", sourceLocation: sourceLocation)
                    continue
                }
                #expect(actualMap == mapDict, "[\(fixture)] '\(sectionName).\(keyName)' map mismatch", sourceLocation: sourceLocation)
            } else {
                #expect(key.stringValue == expectedValue, "[\(fixture)] '\(sectionName).\(keyName)': expected '\(expectedValue)' got '\(key.stringValue)'", sourceLocation: sourceLocation)
            }
        }
    }
}
