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
        case accessRequired(URL)
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

        do {
            try withStoredDirectory(record: record) { _, refreshedRecord in
                updateStatus(for: refreshedRecord)
            }
        } catch CLIControllerError.accessDenied {
            status = .accessRequired(URL(filePath: record.commandPath))
        } catch {
            status = .failed(error.localizedDescription)
        }
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
            let bookmark = try storage.makeBookmark(for: directoryURL)
            try linkManager.install(
                commandURL: commandURL,
                targetURL: embeddedExecutableURL,
                previousTargetURL: previousTargetURL
            )
            let record = CLIInstallationRecord(
                directoryBookmark: bookmark,
                commandPath: commandURL.path,
                targetPath: embeddedExecutableURL.path
            )
            storage.save(record)
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

        do {
            try withStoredDirectory(record: record) { _, refreshedRecord in
                let commandURL = URL(filePath: refreshedRecord.commandPath)
                try linkManager.install(
                    commandURL: commandURL,
                    targetURL: embeddedExecutableURL,
                    previousTargetURL: URL(filePath: refreshedRecord.targetPath)
                )
                let updatedRecord = CLIInstallationRecord(
                    directoryBookmark: refreshedRecord.directoryBookmark,
                    commandPath: commandURL.path,
                    targetPath: embeddedExecutableURL.path
                )
                storage.save(updatedRecord)
                status = .installed(commandURL)
            }
        } catch CLIControllerError.accessDenied {
            status = .accessRequired(URL(filePath: record.commandPath))
        } catch let error as CLIInstallationError {
            if case .destinationConflict = error {
                status = .conflict(URL(filePath: record.commandPath))
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

        do {
            try withStoredDirectory(record: record) { _, refreshedRecord in
                try linkManager.uninstall(
                    commandURL: URL(filePath: refreshedRecord.commandPath),
                    targetURL: embeddedExecutableURL,
                    previousTargetURL: URL(filePath: refreshedRecord.targetPath)
                )
                storage.clear()
                status = .notInstalled
            }
        } catch CLIControllerError.accessDenied {
            status = .accessRequired(URL(filePath: record.commandPath))
        } catch let error as CLIInstallationError {
            if case .destinationConflict = error {
                status = .conflict(URL(filePath: record.commandPath))
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

    private func withStoredDirectory(
        record: CLIInstallationRecord,
        perform operation: (URL, CLIInstallationRecord) throws -> Void
    ) throws {
        let resolved = try storage.resolveBookmark(record.directoryBookmark)
        guard resolved.url.startAccessingSecurityScopedResource() else {
            throw CLIControllerError.accessDenied
        }
        defer { resolved.url.stopAccessingSecurityScopedResource() }

        var refreshedRecord = record
        if resolved.isStale {
            let bookmark = try storage.makeBookmark(for: resolved.url)
            refreshedRecord = CLIInstallationRecord(
                directoryBookmark: bookmark,
                commandPath: record.commandPath,
                targetPath: record.targetPath
            )
            storage.save(refreshedRecord)
        }
        try operation(resolved.url, refreshedRecord)
    }
}

private enum CLIControllerError: Error {
    case accessDenied
}
