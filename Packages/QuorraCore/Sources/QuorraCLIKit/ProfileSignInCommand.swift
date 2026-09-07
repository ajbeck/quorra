import ArgumentParser
import Darwin
import Dispatch
import Foundation
import QuorraIPC

struct ProfileSignInCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sign-in",
        abstract: "Sign in to the IAM Identity Center session used by a profile."
    )

    @Argument(help: "Profile name to authenticate.")
    var profile: String

    func run() async throws {
        let client = IPCCommandClient()
        let initial: QuorraProfileSignInOperationRecord = try client.payload(
            operation: .profileSignInStart,
            arguments: ["profile": profile]
        )

        print("Starting sign-in for \(initial.profileName) using session \(initial.sessionName)…")
        let completed = try await waitForCompletion(initial, client: client)
        switch completed.state {
        case .succeeded:
            print("Signed in to \(completed.profileName).")
        case .failed:
            throw QuorraCLIRuntimeError(
                description: completed.message ?? "Quorra could not complete sign-in."
            )
        case .cancelled:
            throw QuorraCLIRuntimeError(description: "Sign-in was cancelled.")
        case .starting, .waitingForUser:
            throw QuorraCLIRuntimeError(
                description: "Quorra returned an incomplete sign-in operation."
            )
        }
    }

    private func waitForCompletion(
        _ initial: QuorraProfileSignInOperationRecord,
        client: IPCCommandClient
    ) async throws -> QuorraProfileSignInOperationRecord {
        Darwin.signal(SIGINT, SIG_IGN)
        let waitTask = Task {
            try await withTaskCancellationHandler {
                try await poll(initial, client: client)
            } onCancel: {
                _ = try? client.payload(
                    operation: .profileSignInCancel,
                    arguments: ["operation": initial.id.uuidString],
                    as: QuorraProfileSignInOperationRecord.self
                )
            }
        }
        let interruptSource = DispatchSource.makeSignalSource(
            signal: SIGINT,
            queue: .global(qos: .userInitiated)
        )
        interruptSource.setEventHandler {
            waitTask.cancel()
        }
        interruptSource.resume()
        defer {
            interruptSource.cancel()
            Darwin.signal(SIGINT, SIG_DFL)
        }

        do {
            return try await waitTask.value
        } catch is CancellationError {
            throw QuorraCLIRuntimeError(description: "Sign-in was cancelled.")
        }
    }

    private func poll(
        _ initial: QuorraProfileSignInOperationRecord,
        client: IPCCommandClient
    ) async throws -> QuorraProfileSignInOperationRecord {
        var record = initial
        var announcedBrowser = false
        while !record.state.isTerminal {
            if record.state == .waitingForUser, !announcedBrowser {
                print("Complete sign-in in the Quorra window. Press Control-C to cancel.")
                announcedBrowser = true
            }

            try await Task.sleep(for: .milliseconds(400))
            try Task.checkCancellation()
            record = try client.payload(
                operation: .profileSignInStatus,
                arguments: ["operation": record.id.uuidString]
            )
        }
        return record
    }
}
