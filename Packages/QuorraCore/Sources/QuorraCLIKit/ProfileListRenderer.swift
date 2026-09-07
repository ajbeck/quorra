import Foundation
import QuorraProfiles

enum ProfileListRenderer {
    static func render(_ items: [SidebarProfileItem], format: ProfileListOutputFormat) throws -> String {
        let records = items.map(ProfileListRecord.init)
        switch format {
        case .table:
            return renderTable(records)
        case .names:
            return records.map(\.name).joined(separator: "\n")
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(records), as: UTF8.self)
        }
    }

    private static func renderTable(_ records: [ProfileListRecord]) -> String {
        let headers = ["NAME", "SOURCE", "SESSION", "REGION", "ACCOUNT", "ROLE"]
        let rows = records.map { record in
            [
                record.name,
                record.source,
                record.session ?? "—",
                record.region ?? "—",
                record.account ?? "—",
                record.role ?? "—",
            ]
        }
        let widths = headers.indices.map { column in
            ([headers[column]] + rows.map { $0[column] }).map(\.count).max() ?? 0
        }

        return ([headers] + rows).map { row in
            row.indices.map { column in
                row[column].padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }
}
