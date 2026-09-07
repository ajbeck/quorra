import Foundation
import QuorraIPC

struct IPCCommandClient: Sendable {
    func payload<Payload: Decodable & Sendable>(
        operation: QuorraIPCOperation,
        arguments: [String: String] = [:],
        as type: Payload.Type = Payload.self
    ) throws -> Payload {
        let response: QuorraIPCResponse
        do {
            response = try QuorraIPCClient(timeout: timeout(for: operation)).send(
                QuorraIPCRequest(operation: operation, arguments: arguments)
            )
        } catch QuorraIPCClientError.appNotRunning {
            throw QuorraCLIRuntimeError(
                description: "Quorra is not running. Run `quorra start` and try again."
            )
        }
        if let error = response.error {
            throw QuorraCLIRuntimeError(description: error.message)
        }
        guard response.status == .success else {
            throw QuorraCLIRuntimeError(description: "Quorra could not complete the command.")
        }
        return try response.decodePayload(as: type)
    }

    private func timeout(for operation: QuorraIPCOperation) -> TimeInterval {
        switch operation {
        case .imdsStart, .imdsSwitchProfile:
            return 30
        case .handshake,
             .appTerminate,
             .profileSignInStart,
             .profileSignInStatus,
             .profileSignInCancel,
             .imdsList,
             .imdsStatus,
             .imdsStop:
            return 2
        }
    }
}
