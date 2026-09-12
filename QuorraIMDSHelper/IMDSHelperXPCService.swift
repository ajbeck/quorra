import Foundation
import QuorraIMDSHelperCore
import QuorraIPC

final class IMDSHelperXPCService: NSObject, QuorraIMDSHelperXPCProtocol, @unchecked Sendable {
    private let service: IMDSHelperService

    init(service: IMDSHelperService) {
        self.service = service
    }

    func status(reply: @escaping (String, String?) -> Void) {
        let reply = XPCReply(reply)
        Task { @MainActor [service] in
            let snapshot = Self.snapshot(for: service.state)
            reply.send(snapshot.state.rawValue, snapshot.failureMessage)
        }
    }

    func enable(reply: @escaping (String, String?) -> Void) {
        let reply = XPCReply(reply)
        Task { @MainActor [service] in
            do {
                try await service.enable()
            } catch {
                // The service records the actionable failure in its state.
            }
            let snapshot = Self.snapshot(for: service.state)
            reply.send(snapshot.state.rawValue, snapshot.failureMessage)
        }
    }

    func disable(reply: @escaping (String, String?) -> Void) {
        let reply = XPCReply(reply)
        Task { @MainActor [service] in
            do {
                try service.disable()
            } catch {
                // The service records the actionable failure in its state.
            }
            let snapshot = Self.snapshot(for: service.state)
            reply.send(snapshot.state.rawValue, snapshot.failureMessage)
        }
    }

    @MainActor
    private static func snapshot(
        for state: IMDSHelperServiceState
    ) -> (state: QuorraIMDSHelperState, failureMessage: String?) {
        switch state {
        case .disabled:
            return (.disabled, nil)
        case .enabling:
            return (.enabling, nil)
        case .enabled:
            return (.enabled, nil)
        case .disabling:
            return (.disabling, nil)
        case .failed(let message):
            return (.failed, message)
        }
    }
}

private final class XPCReply: @unchecked Sendable {
    private let closure: (String, String?) -> Void

    init(_ closure: @escaping (String, String?) -> Void) {
        self.closure = closure
    }

    func send(_ state: String, _ failureMessage: String?) {
        closure(state, failureMessage)
    }
}

final class IMDSHelperXPCListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let exportedService: IMDSHelperXPCService

    init(service: IMDSHelperService) {
        exportedService = IMDSHelperXPCService(service: service)
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(
            with: QuorraIMDSHelperXPCProtocol.self
        )
        connection.exportedObject = exportedService
        connection.activate()
        return true
    }
}
