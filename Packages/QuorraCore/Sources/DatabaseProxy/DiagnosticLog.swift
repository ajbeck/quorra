import Foundation
import IAMIdentityCenter
import OSLog

public nonisolated enum DiagnosticEvent: String, Codable, Sendable {
    case endpointStarting, endpointCheckingUpstream, endpointUpstreamVerified, endpointListening, endpointStopped, endpointFailed
    case clientAccepted, clientRejected, clientAuthenticated, clientClosed, clientFailed, handshakeTimedOut
    case upstreamConnecting, upstreamAuthenticated, upstreamFailed, cancellationForwarded, cancellationFailed
    case tlsVerified, tlsVerificationFailed
    case connectionTestStarted, connectionTestSucceeded, connectionTestFailed
    case eventsDropped

    public var category: String {
        self == .eventsDropped ? "diagnostics" : "proxy"
    }

    public var level: String {
        switch self {
        case .endpointFailed, .clientFailed, .upstreamFailed, .cancellationFailed,
             .connectionTestFailed, .tlsVerificationFailed: "error"
        case .clientRejected, .handshakeTimedOut, .eventsDropped: "warning"
        default: "info"
        }
    }
}

/// Only known error families are recorded. Never serialize arbitrary errors,
/// localized descriptions, HTTP responses, connection strings, or SQL.
public nonisolated struct DiagnosticFailure: Codable, Sendable {
    public let code: String
    public let status: Int32?

    init(_ error: any Error) {
        status = (error as? DatabaseCertificateFailure)?.status
        switch error {
        case is CancellationError: code = "cancelled"
        case let failure as ProxyError: code = "proxy.\(String(describing: failure))"
        case is IAMIdentityCenterError: code = "aws.credentials"
        case is DatabaseCertificateFailure: code = "tls.certificateVerification"
        case is ConfigurationError: code = "configuration.invalid"
        default: code = "unexpected"
        }
    }
}

public nonisolated struct DiagnosticEntry: Codable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let timestamp: Date
    public let runID: UUID
    public let event: DiagnosticEvent
    public let category: String
    public let level: String
    public let connectionID: UUID?
    public let clientID: UUID?
    public let count: Int?
    public let failure: DiagnosticFailure?
}

/// Immutable entry values cross threads. Admission counters are lock-protected;
/// file state belongs exclusively to queue. Disk I/O never runs on the UI actor.
public nonisolated final class DiagnosticLog: @unchecked Sendable {
    static let subsystem = "dev.ajbeck.quorra"
    public static let disabled = DiagnosticLog(directory: nil, mirrorsToSystemLog: false)

    let directory: URL?
    let runID = UUID()
    private let maximumFileBytes: Int
    private let maximumFiles: Int
    private let maximumPending: Int
    private let mirrorsToSystemLog: Bool
    private let queue = DispatchQueue(label: "dev.ajbeck.quorra.database-proxy.diagnostics", qos: .utility)
    private let admission = NSLock()
    private var pending = 0
    private var dropped = 0
    // Accessed only on queue.
    private var fileFailure = false
    private let encoder: JSONEncoder
    private let sink: (@Sendable (DiagnosticEntry) -> Void)?

    /// Events go to unified logging and to `sink`, which receives each entry in order on the
    /// log's own queue. Quorra writes no diagnostic file; tests pass a directory.
    public convenience init(sink: @escaping @Sendable (DiagnosticEntry) -> Void) {
        self.init(directory: nil, sink: sink)
    }

    init(directory: URL?, maximumFileBytes: Int = 2 * 1024 * 1024, maximumFiles: Int = 5,
         maximumPending: Int = 1024, mirrorsToSystemLog: Bool = true, sink: (@Sendable (DiagnosticEntry) -> Void)? = nil) {
        self.sink = sink
        self.directory = directory
        self.maximumFileBytes = max(1024, maximumFileBytes)
        self.maximumFiles = max(1, maximumFiles)
        self.maximumPending = max(1, maximumPending)
        self.mirrorsToSystemLog = mirrorsToSystemLog
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    /// A closed, typed payload prevents callers from accidentally logging secrets.
    func record(_ event: DiagnosticEvent, connectionID: UUID? = nil, clientID: UUID? = nil, count: Int? = nil,
                error: (any Error)? = nil) {
        guard directory != nil || mirrorsToSystemLog || sink != nil else { return }
        let entry = entry(event, connectionID: connectionID, clientID: clientID, count: count, error: error)
        admission.lock()
        guard pending < maximumPending else { dropped += 1; admission.unlock(); return }
        pending += 1
        // Enqueue while holding the admission lock to preserve record order.
        queue.async { [self] in
            write(entry)
            admission.lock()
            let lost = dropped
            dropped = 0
            pending -= 1
            admission.unlock()
            if lost > 0 { write(self.entry(.eventsDropped, count: lost)) }
        }
        admission.unlock()
    }

    private func entry(_ event: DiagnosticEvent, connectionID: UUID? = nil, clientID: UUID? = nil, count: Int? = nil,
                       error: (any Error)? = nil) -> DiagnosticEntry {
        .init(schemaVersion: 1, id: UUID(), timestamp: .now, runID: runID, event: event,
              category: event.category, level: event.level, connectionID: connectionID,
              clientID: clientID, count: count, failure: error.map(DiagnosticFailure.init))
    }

    /// Barrier for orderly termination and tests. Normal recording is asynchronous.
    func flush() { queue.sync {} }

    /// Bounded read API for a future viewer. Ignores a partial crash-tail record.
    func recentEntries(limit: Int = 500) async throws -> [DiagnosticEntry] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    var result: [DiagnosticEntry] = []
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    for index in (0..<maximumFiles).reversed() {
                        guard let url = file(index), FileManager.default.fileExists(atPath: url.path) else { continue }
                        let data = try Data(contentsOf: url)
                        for line in data.split(separator: 10) {
                            if let entry = try? decoder.decode(DiagnosticEntry.self, from: Data(line)) { result.append(entry) }
                        }
                    }
                    continuation.resume(returning: Array(result.suffix(max(0, min(limit, 10_000)))))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func prepareDirectory() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { continuation.resume(returning: try ensureDirectory()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func file(_ index: Int) -> URL? {
        directory?.appending(path: index == 0 ? "database-proxy.jsonl" : "database-proxy.\(index).jsonl")
    }

    private func ensureDirectory() throws -> URL {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    private func write(_ entry: DiagnosticEntry) {
        sink?(entry)
        guard let data = try? encoder.encode(entry) else { return }
        if mirrorsToSystemLog, let message = String(data: data, encoding: .utf8) {
            let logger = Logger(subsystem: Self.subsystem, category: entry.category)
            // Every field has already passed the typed, non-secret payload boundary.
            switch entry.level {
            case "error": logger.error("\(message, privacy: .public)")
            case "warning": logger.warning("\(message, privacy: .public)")
            default: logger.notice("\(message, privacy: .public)")
            }
        }
        guard let current = file(0) else { return }
        do {
            _ = try ensureDirectory()
            var line = data
            line.append(10)
            let fm = FileManager.default
            if fm.fileExists(atPath: current.path) {
                let size = (try fm.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
                if size + line.count > maximumFileBytes {
                    if let oldest = file(maximumFiles - 1), fm.fileExists(atPath: oldest.path) { try fm.removeItem(at: oldest) }
                    if maximumFiles > 1 {
                        for index in stride(from: maximumFiles - 2, through: 0, by: -1) {
                            let source = file(index)!, destination = file(index + 1)!
                            if fm.fileExists(atPath: source.path) { try fm.moveItem(at: source, to: destination) }
                        }
                    }
                }
            }
            if !fm.fileExists(atPath: current.path) {
                guard fm.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forUpdating: current)
            defer { try? handle.close() }
            let length = try handle.seekToEnd()
            if length > 0 {
                try handle.seek(toOffset: length - 1)
                let tail = try handle.read(upToCount: 1)
                try handle.seekToEnd()
                if tail != Data([10]) { try handle.write(contentsOf: Data([10])) }
            }
            try handle.write(contentsOf: line)
            if fileFailure {
                Logger(subsystem: Self.subsystem, category: "diagnostics").notice("Persistent diagnostic logging recovered.")
            }
            fileFailure = false
        } catch {
            if !fileFailure {
                Logger(subsystem: Self.subsystem, category: "diagnostics").error("Persistent diagnostic logging unavailable; events continue in unified logging. The next event will retry file storage.")
            }
            fileFailure = true
        }
    }
}
