import AWSConfigINI
import Foundation
import Observation
import OSLog
import QuorraAppLogic
import QuorraProfiles
import SwiftData

private let exportLogger = Logger(subsystem: "dev.ajbeck.quorra", category: "IdentityExport")

/// Keeps the AWS config file in step with the identity store while export is on, and runs the manual
/// re-import. Failures are recorded for Settings to show instead of being raised as alerts.
@MainActor
@Observable
final class IdentityExportCoordinator {
    private(set) var isExporting = false
    private(set) var lastExportFailure: String?
    private(set) var isImporting = false
    private(set) var lastImportMessage: String?

    @ObservationIgnored private let appModel: AppModel
    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let storage: IdentityExportStorage
    @ObservationIgnored private var storeSaveObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var exportRequested = false

    init(appModel: AppModel, modelContext: ModelContext, storage: IdentityExportStorage = .default) {
        self.appModel = appModel
        self.modelContext = modelContext
        self.storage = storage
    }

    /// Follows store saves; each save that touches a session or profile exports once.
    func start() {
        guard storeSaveObserver == nil else { return }
        storeSaveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: modelContext,
            queue: .main
        ) { [weak self] notification in
            guard Self.saveAffectsIdentity(notification) else { return }
            Task { @MainActor [weak self] in
                await self?.exportIfEnabled()
            }
        }
    }

    /// Writes the store to the config file when export is on and the folder is available. Saves that
    /// arrive while an export is running are folded into one follow-up export.
    func exportIfEnabled() async {
        guard appModel.mode == .managed, case .ready(let folderURL) = appModel.phase else { return }
        exportRequested = true
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }

        let configURL = folderURL.appending(path: "config", directoryHint: .notDirectory)
        while exportRequested {
            exportRequested = false
            await export(to: configURL)
        }
    }

    private func export(to configURL: URL) async {
        do {
            let snapshot = try IdentityExportSnapshot.capture(in: modelContext)
            let previous = storage.load()
            // The write takes the shared file lock and polls for it; keep that off the main actor.
            let result = try await Task.detached(priority: .utility) {
                try IdentityStoreExporter.export(snapshot, previous: previous, toConfigAt: configURL)
            }.value
            storage.save(result.record)
            lastExportFailure = nil
            exportLogger.info("Exported \(result.summary.sessions) sessions and \(result.summary.profiles) profiles; removed \(result.summary.removedSessions) sessions and \(result.summary.removedProfiles) profiles.")
        } catch {
            lastExportFailure = error.localizedDescription
            exportLogger.error("Identity export failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads the AWS folder again and adds or updates its sessions and profiles in the store.
    /// Nothing is deleted; deleting stays a Quorra action.
    func reimport() async {
        guard case .ready(let folderURL) = appModel.phase, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let catalog = try await Task.detached(priority: .userInitiated) {
                try ProfileCatalogLoader.load(folder: folderURL)
            }.value
            let summary = try IdentityStoreImporter.importSSOProfiles(from: catalog.groups, into: modelContext)
            lastImportMessage = Self.message(for: summary)
        } catch {
            lastImportMessage = "Re-import failed: \(error.localizedDescription)"
        }
    }

    private static func message(for summary: IdentityImportSummary) -> String {
        var message = "Imported \(count(summary.sessions, "session")) and \(count(summary.profiles, "profile"))."
        if !summary.skippedProfiles.isEmpty {
            message += " \(count(summary.skippedProfiles.count, "profile")) stayed in the file because they are incomplete or do not use IAM Identity Center."
        }
        return message
    }

    private static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    private nonisolated static func saveAffectsIdentity(_ notification: Notification) -> Bool {
        let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        let entityNames: Set<String> = ["SessionDefinition", "ProfileDefinition"]
        return keys.contains { key in
            guard let identifiers = notification.userInfo?[key] as? [PersistentIdentifier] else { return false }
            return identifiers.contains { entityNames.contains($0.entityName) }
        }
    }
}

#if DEBUG
extension IdentityExportCoordinator {
    static func preview(failure: String? = nil, importMessage: String? = nil) -> IdentityExportCoordinator {
        let coordinator = IdentityExportCoordinator(
            appModel: AppModel(initialPhase: .setup),
            modelContext: PreviewIdentityFixtures.makeContainer().mainContext,
            storage: IdentityExportStorage(defaults: UserDefaults(suiteName: "dev.ajbeck.quorra.preview.export")!)
        )
        coordinator.lastExportFailure = failure
        coordinator.lastImportMessage = importMessage
        return coordinator
    }
}
#endif
