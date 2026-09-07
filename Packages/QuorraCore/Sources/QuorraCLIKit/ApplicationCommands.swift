import AppKit
import ArgumentParser
import Foundation
import QuorraIPC

struct QuorraStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start the Quorra app."
    )

    mutating func run() async throws {
        if QuorraApplicationController.isResponsive {
            print("Quorra is already running.")
            return
        }

        guard let applicationURL = await QuorraApplicationController.applicationURL() else {
            throw ValidationError(
                "Quorra.app could not be found. Reinstall Quorra and its command-line tool."
            )
        }

        try await QuorraApplicationController.launch(applicationURL)

        for _ in 0..<50 {
            if QuorraApplicationController.isResponsive {
                print("Quorra started.")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        throw ValidationError(
            "Quorra opened, but its command service did not become available. Open Quorra to check for an error."
        )
    }
}

struct QuorraStopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the running Quorra app."
    )

    func run() throws {
        let response = try QuorraIPCClient().send(
            QuorraIPCRequest(operation: .appTerminate)
        )
        if let error = response.error {
            throw ValidationError(error.message)
        }
        guard response.status == .success else {
            throw ValidationError("Quorra could not stop.")
        }
        _ = try response.decodePayload(as: QuorraIPCAcknowledgement.self)
        print("Quorra is stopping.")
    }
}

private enum QuorraApplicationController {
    static var isResponsive: Bool {
        do {
            let response = try QuorraIPCClient().send(
                QuorraIPCRequest(operation: .handshake)
            )
            return response.status == .success
        } catch {
            return false
        }
    }

    @MainActor
    static func applicationURL() -> URL? {
        var candidate = Bundle.main.bundleURL.deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
               Bundle(url: candidate)?.bundleIdentifier == QuorraIPCProtocol.appIdentifier {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }

        return NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: QuorraIPCProtocol.appIdentifier
        )
    }

    @MainActor
    static func launch(_ applicationURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if application == nil {
                    continuation.resume(
                        throwing: QuorraApplicationCommandError.launchDidNotReturnApplication
                    )
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

private enum QuorraApplicationCommandError: LocalizedError {
    case launchDidNotReturnApplication

    var errorDescription: String? {
        "macOS did not return a running Quorra application after launch."
    }
}
