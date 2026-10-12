import Foundation
import Observation
import QuorraAppLogic

@Observable
@MainActor
final class CLIInstallationController {
    enum Status: Equatable {
        case unavailable
        case notInstalled
        case installed(URL)
        case repairNeeded(URL)
        case conflict(URL)
        case failed(String)
    }

    private(set) var status: Status = .notInstalled

    @ObservationIgnored private let embeddedExecutableURL: URL
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let linkManager: CLIInstallationLinkManager
    @ObservationIgnored private let storage: CLIInstallationStorage

    init(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        storage: CLIInstallationStorage = .default
    ) {
        embeddedExecutableURL = bundle.bundleURL
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Helpers", directoryHint: .isDirectory)
            .appending(path: "QuorraCLI.app", directoryHint: .isDirectory)
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "MacOS", directoryHint: .isDirectory)
            .appending(path: "quorra-cli", directoryHint: .notDirectory)
        self.fileManager = fileManager
        linkManager = CLIInstallationLinkManager(fileManager: fileManager)
        self.storage = storage
    }

    func refresh() {
        guard embeddedExecutableIsAvailable else {
            status = .unavailable
            return
        }
        guard let record = storage.load() else {
            status = .notInstalled
            return
        }
        updateStatus(for: record)
    }

    /// Installs into `~/.local/bin`, creating it when needed.
    func installInDefaultFolder() {
        do {
            try fileManager.createDirectory(at: CLIInstallationStorage.defaultDirectory, withIntermediateDirectories: true)
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        install(in: CLIInstallationStorage.defaultDirectory)
    }

    func install(in directoryURL: URL) {
        guard embeddedExecutableIsAvailable else {
            status = .unavailable
            return
        }

        let commandURL = directoryURL.appending(path: "quorra", directoryHint: .notDirectory)
        let existingRecord = storage.load()
        let previousTargetURL = existingRecord.flatMap { record in
            record.commandPath == commandURL.path ? URL(filePath: record.targetPath) : nil
        }

        do {
            try linkManager.install(
                commandURL: commandURL,
                targetURL: embeddedExecutableURL,
                previousTargetURL: previousTargetURL
            )
            storage.save(CLIInstallationRecord(commandPath: commandURL.path, targetPath: embeddedExecutableURL.path))
            status = .installed(commandURL)
        } catch let error as CLIInstallationError {
            if case .destinationConflict = error {
                status = .conflict(commandURL)
            } else {
                status = .failed(error.localizedDescription)
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func repair() {
        guard embeddedExecutableIsAvailable else {
            status = .unavailable
            return
        }
        guard let record = storage.load() else {
            status = .notInstalled
            return
        }

        let commandURL = URL(filePath: record.commandPath)
        do {
            try linkManager.install(
                commandURL: commandURL,
                targetURL: embeddedExecutableURL,
                previousTargetURL: URL(filePath: record.targetPath)
            )
            storage.save(CLIInstallationRecord(commandPath: commandURL.path, targetPath: embeddedExecutableURL.path))
            status = .installed(commandURL)
        } catch let error as CLIInstallationError {
            if case .destinationConflict = error {
                status = .conflict(commandURL)
            } else {
                status = .failed(error.localizedDescription)
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func uninstall() {
        guard let record = storage.load() else {
            status = .notInstalled
            return
        }

        let commandURL = URL(filePath: record.commandPath)
        do {
            try linkManager.uninstall(
                commandURL: commandURL,
                targetURL: embeddedExecutableURL,
                previousTargetURL: URL(filePath: record.targetPath)
            )
            storage.clear()
            status = .notInstalled
        } catch let error as CLIInstallationError {
            if case .destinationConflict = error {
                status = .conflict(commandURL)
            } else {
                status = .failed(error.localizedDescription)
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private var embeddedExecutableIsAvailable: Bool {
        fileManager.isExecutableFile(atPath: embeddedExecutableURL.path)
    }

    private func updateStatus(for record: CLIInstallationRecord) {
        let commandURL = URL(filePath: record.commandPath)
        switch linkManager.status(
            commandURL: commandURL,
            targetURL: embeddedExecutableURL,
            previousTargetURL: URL(filePath: record.targetPath)
        ) {
        case .missing, .repairable:
            status = .repairNeeded(commandURL)
        case .installed:
            status = .installed(commandURL)
        case .conflict:
            status = .conflict(commandURL)
        }
    }
}
