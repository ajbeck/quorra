import Foundation
import Network

/// The listener's answer to one browser request.
package struct LoopbackCallbackReply<Value: Sendable>: Sendable {
    package let page: CallbackPage
    /// What the sign-in produced, or nil to keep waiting, for example after an unrelated request.
    package let outcome: Result<Value, any Error>?

    package init(page: CallbackPage, outcome: Result<Value, any Error>?) {
        self.page = page
        self.outcome = outcome
    }
}

/// One-use HTTP callback server for a browser sign-in. It binds only to IPv4 loopback, has a fixed
/// lifetime, caps request size and concurrency, and never logs or echoes request data.
@MainActor
package final class LoopbackCallbackListener<Value: Sendable> {
    package typealias Handler = @MainActor (_ request: LoopbackHTTPRequest, _ port: UInt16) -> LoopbackCallbackReply<Value>

    private let port: NWEndpoint.Port
    private let limits: LoopbackHTTPRequest.Limits
    private let lifetime: Duration
    private let unavailable: any Error
    private let timedOut: any Error
    private let rejectedPage: CallbackPage
    private let handler: Handler
    private var listener: NWListener?
    private var ready: CheckedContinuation<UInt16, any Error>?
    private var waiter: CheckedContinuation<Value, any Error>?
    private var outcome: Result<Value, any Error>?
    private var timeout: Task<Void, Never>?
    private var connections: [UUID: NWConnection] = [:]
    private var connectionTimeouts: [UUID: Task<Void, Never>] = [:]
    private var boundPort: UInt16 = 0

    /// - Parameters:
    ///   - port: `.any` lets the system choose; a fixed port is for callers that can't pass one to the browser.
    ///   - unavailable: Thrown when the port can't be bound.
    ///   - timedOut: Thrown when `lifetime` passes without an outcome.
    ///   - rejectedPage: Shown for a request that can't be read; the listener keeps waiting.
    package init(
        port: NWEndpoint.Port = .any,
        limits: LoopbackHTTPRequest.Limits,
        lifetime: Duration,
        unavailable: any Error,
        timedOut: any Error,
        rejectedPage: CallbackPage,
        handler: @escaping Handler
    ) {
        self.port = port
        self.limits = limits
        self.lifetime = lifetime
        self.unavailable = unavailable
        self.timedOut = timedOut
        self.rejectedPage = rejectedPage
        self.handler = handler
    }

    /// Starts listening and returns the bound port.
    package func start() async throws -> UInt16 {
        try Task.checkCancellation()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) }
        catch { throw unavailable }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.listenerChanged(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        let lifetime = lifetime
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: lifetime) } catch { return }
            guard let self else { return }
            self.finish(.failure(self.timedOut))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                ready = $0
                if Task.isCancelled { cancel() } else { listener.start(queue: .main) }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    /// Waits for the browser to deliver the sign-in's outcome.
    package func value() async throws -> Value {
        try await withTaskCancellationHandler {
            if let outcome { return try outcome.get() }
            return try await withCheckedThrowingContinuation {
                waiter = $0
                if Task.isCancelled { cancel() }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    package func cancel(with error: any Error = CancellationError()) {
        finish(.failure(error))
    }

    private func listenerChanged(_ state: NWListener.State) {
        guard outcome == nil else { return }
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else {
                finish(.failure(unavailable))
                return
            }
            boundPort = port
            ready?.resume(returning: port)
            ready = nil
        case .failed:
            finish(.failure(unavailable))
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard outcome == nil, connections.count < 8 else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        connectionTimeouts[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.close(id)
        }
        connection.start(queue: .main)
        receive(id, accumulated: Data())
    }

    private func receive(_ id: UUID, accumulated: Data) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(64 * 1_024, limits.total - accumulated.count)) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var buffer = accumulated
                if let data { buffer.append(data) }
                do {
                    if let request = try LoopbackHTTPRequest(parsing: buffer, limits: self.limits) {
                        let reply = self.handler(request, self.boundPort)
                        self.respond(id, page: reply.page, outcome: reply.outcome)
                    } else if error != nil || complete || buffer.count >= self.limits.total {
                        self.close(id)
                    } else {
                        self.receive(id, accumulated: buffer)
                    }
                } catch {
                    // A request that can't be read must not end a sign-in that's still valid.
                    self.respond(id, page: self.rejectedPage, outcome: nil)
                }
            }
        }
    }

    private func respond(_ id: UUID, page: CallbackPage, outcome: Result<Value, any Error>?) {
        connections[id]?.send(content: page.response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                self?.close(id)
                if let outcome { self?.finish(outcome) }
            }
        })
    }

    private func close(_ id: UUID) {
        connectionTimeouts.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }

    private func finish(_ result: Result<Value, any Error>) {
        guard outcome == nil else { return }
        outcome = result
        timeout?.cancel()
        listener?.cancel()
        listener = nil
        for id in Array(connections.keys) {
            close(id)
        }
        if let ready {
            self.ready = nil
            switch result {
            case .failure(let error): ready.resume(throwing: error)
            case .success: ready.resume(throwing: unavailable)
            }
        }
        waiter?.resume(with: result)
        waiter = nil
    }
}
