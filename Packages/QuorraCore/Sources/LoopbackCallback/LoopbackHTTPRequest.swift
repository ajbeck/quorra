import Foundation

package struct LoopbackHTTPRequestError: Error, Equatable {}

/// One HTTP/1.1 request to a loopback callback, read within fixed size limits.
///
/// A body needs exactly one decimal `Content-Length`; `Transfer-Encoding` and trailing bytes are
/// refused, so a request can be framed only one way.
package struct LoopbackHTTPRequest: Sendable {
    package struct Limits: Sendable {
        package var header: Int
        package var body: Int

        package init(header: Int, body: Int) {
            self.header = header
            self.body = body
        }

        package var total: Int { header + 4 + body }
    }

    /// The request line and header fields, through the blank line that ends them.
    package let head: Data
    package let method: String
    package let target: String
    /// Header values by lowercased field name, in arrival order.
    package let fields: [String: [String]]
    package let body: Data

    /// Reads a request from the bytes received so far, or returns nil while more are needed.
    package init?(parsing buffer: Data, limits: Limits) throws {
        let bytes = Data(buffer)
        guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            guard bytes.count <= limits.header else { throw LoopbackHTTPRequestError() }
            return nil
        }
        guard end.lowerBound <= limits.header, let text = String(data: bytes[..<end.lowerBound], encoding: .utf8) else {
            throw LoopbackHTTPRequestError()
        }
        let lines = text.components(separatedBy: "\r\n")
        let start = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard start.count == 3, start[2] == "HTTP/1.1", !start[0].isEmpty, !start[1].isEmpty else { throw LoopbackHTTPRequestError() }

        var fields: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { throw LoopbackHTTPRequestError() }
            let name = line[..<separator].lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { throw LoopbackHTTPRequestError() }
            fields[name, default: []].append(value)
        }
        guard fields["transfer-encoding"] == nil else { throw LoopbackHTTPRequestError() }

        var length = 0
        if let lengths = fields["content-length"] {
            guard lengths.count == 1, lengths[0].utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(lengths[0]), value <= limits.body else { throw LoopbackHTTPRequestError() }
            length = value
        }
        let received = bytes.count - end.upperBound
        guard received <= length else { throw LoopbackHTTPRequestError() }
        guard received == length else { return nil }

        head = Data(bytes[..<end.upperBound])
        method = String(start[0])
        target = String(start[1])
        self.fields = fields
        body = Data(bytes[end.upperBound...])
    }
}
