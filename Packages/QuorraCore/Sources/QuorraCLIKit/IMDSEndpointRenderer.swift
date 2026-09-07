import ArgumentParser
import Foundation
import QuorraIPC

enum IMDSOutputFormat: String, CaseIterable, ExpressibleByArgument {
    case table
    case json
}

enum IMDSEndpointRenderer {
    static func render(
        _ endpoints: [QuorraIMDSEndpointRecord],
        format: IMDSOutputFormat
    ) throws -> String {
        switch format {
        case .json:
            return try json(endpoints)
        case .table:
            guard !endpoints.isEmpty else { return "No IMDS endpoints." }
            let rows = endpoints.map {
                [
                    $0.status.rawValue,
                    address(for: $0),
                    $0.servedProfileName ?? $0.profileName ?? "—",
                    $0.name,
                ]
            }
            return table(headers: ["STATUS", "ADDRESS", "PROFILE", "NAME"], rows: rows)
        }
    }

    static func renderStatus(
        _ endpoint: QuorraIMDSEndpointRecord,
        format: IMDSOutputFormat
    ) throws -> String {
        switch format {
        case .json:
            return try json(endpoint)
        case .table:
            var lines = [
                endpoint.name,
                "Status: \(endpoint.status.rawValue)",
                "Address: \(address(for: endpoint))",
                "Profile: \(endpoint.profileName ?? "—")",
                "Serving: \(endpoint.servedProfileName ?? "—")",
                "ID: \(endpoint.id)",
            ]
            if let failureMessage = endpoint.failureMessage {
                lines.append("Error: \(failureMessage)")
            }
            return lines.joined(separator: "\n")
        }
    }

    static func actionSummary(
        _ action: String,
        endpoint: QuorraIMDSEndpointRecord
    ) -> String {
        "\(action) \(endpoint.name) (\(address(for: endpoint)))."
    }

    private static func address(for endpoint: QuorraIMDSEndpointRecord) -> String {
        "http://\(endpoint.bindAddress):\(endpoint.boundPort ?? endpoint.configuredPort)"
    }

    private static func json<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func table(headers: [String], rows: [[String]]) -> String {
        let widths = headers.indices.map { column in
            ([headers[column]] + rows.map { $0[column] }).map(\.count).max() ?? 0
        }
        let allRows = [headers] + rows
        return allRows.map { row in
            row.indices.map { column in
                column == row.indices.last
                    ? row[column]
                    : row[column].padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }
            .joined(separator: "  ")
        }
        .joined(separator: "\n")
    }
}
