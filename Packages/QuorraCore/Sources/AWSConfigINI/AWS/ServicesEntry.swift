// ServicesEntry.swift — Codable struct for an AWS [services NAME] section.
//
// Plan §5 (D10 lean surface), §13.2 task 5.
//
// The AWS `[services NAME]` format uses two layers of indented sub-properties:
//
//   [services my-services]
//   dynamodb =
//     endpoint_url = http://localhost:1234
//   s3 =
//     endpoint_url = http://localhost:5678
//
// In the Section model, each service name (`dynamodb`, `s3`) is a map-typed Key
// whose mapValue() returns the per-service config dict. The outer keys of
// `entries` are service names; the inner [String: String] maps are the config
// for each service.
//
// The M06 decoder/encoder handle [String: String] as a single map-typed key but
// do not support [String: [String: String]] generically. ServicesEntry uses a
// custom init(from:) and encode(to:) that work directly with the _SectionDecoder
// / _SectionEncoder containers, looping over map-typed keys explicitly.
// Plan §13.2 task 5.

/// A lean model of an AWS `[services NAME]` section.
///
/// `entries` maps service identifiers to their per-service config maps.
/// For example, `entries["dynamodb"]["endpoint_url"]` holds a custom DynamoDB endpoint.
///
/// Implements custom `Codable` conformance because the two-layer nesting
/// (`[String: [String: String]]`) is outside the M06 decoder/encoder's generic support.
/// Plan §13.2 task 5; marshal spec §7.
public struct ServicesEntry: Codable, Sendable, Hashable {
    /// Service name → per-service configuration map.
    /// Keys are service identifiers (e.g. `"dynamodb"`, `"s3"`);
    /// values are the sub-property maps from the INI file.
    public var entries: [String: [String: String]]

    public init(entries: [String: [String: String]] = [:]) {
        self.entries = entries
    }

    // MARK: - Custom Codable

    // Custom init(from:) and encode(to:) are required because [String: [String: String]]
    // does not map to any single M06 decoder/encoder type dispatch path.
    //
    // Decoding: each top-level CodingKey in the container corresponds to a service name
    // whose value is a [String: String] sub-property map. We collect every key the
    // container reports and decode it as [String: String].
    //
    // Encoding: for each entry in `entries`, we encode the inner [String: String] map
    // under the service name key — the M06 encoder recognises [String: String] values
    // and stores them as a Value.map, which the canonical writer emits as indented
    // sub-properties.

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: _ServiceKey.self)
        var result: [String: [String: String]] = [:]
        for key in container.allKeys {
            // Each key's value is a [String: String] sub-property map.
            // `decodeIfPresent` returns nil for scalar-valued keys, silently skipping them.
            // This mirrors the parser's silent-tolerance contract (Decision D06): malformed
            // or unexpected entries don't fail the whole document — they're just dropped.
            if let map = try container.decodeIfPresent([String: String].self, forKey: key) {
                result[key.stringValue] = map
            }
        }
        self.entries = result
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: _ServiceKey.self)
        // Sort by service name for deterministic output: a Swift Dictionary's
        // iteration order is implementation-defined, so re-encoding the same struct
        // could otherwise produce different orderings between runs. Determinism
        // matches the project's D16 ordering ethos and keeps golden-file diffs stable.
        for (service, config) in entries.sorted(by: { $0.key < $1.key }) {
            // The M06 keyed container recognises [String: String] and stores it as
            // Value.map, which the canonical writer emits as the expected indented
            // sub-property format.
            try container.encode(config, forKey: _ServiceKey(stringValue: service)!)
        }
    }
}

// MARK: - Internal CodingKey

/// Dynamic CodingKey for service names, which are not known at compile time.
private struct _ServiceKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
