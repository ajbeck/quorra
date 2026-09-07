import AppKit
import Foundation

enum FolderPicker {
    @MainActor
    static func pickAWSFolder() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = UserHome.awsFolder
        panel.prompt = "Choose"
        panel.title = "Choose your AWS folder"
        panel.message = "The default location is ~/.aws. Create a new folder if one doesn't exist."

        return await withCheckedContinuation { continuation in
            panel.begin { response in
                guard response == .OK else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: panel.urls.first)
            }
        }
    }

    @MainActor
    static func pickCLIInstallFolder() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true

        let preferredDirectory = UserHome.url
            .appending(path: ".local", directoryHint: .isDirectory)
            .appending(path: "bin", directoryHint: .isDirectory)
        panel.directoryURL = existingAncestor(of: preferredDirectory)
        panel.prompt = "Install Here"
        panel.title = "Choose where to install the Quorra command"
        panel.message = "Quorra will create a command named “quorra” in this folder. ~/.local/bin is recommended."

        return await withCheckedContinuation { continuation in
            panel.begin { response in
                guard response == .OK else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: panel.urls.first)
            }
        }
    }

    private static func existingAncestor(of url: URL) -> URL {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path),
              candidate.path != candidate.deletingLastPathComponent().path {
            candidate.deleteLastPathComponent()
        }
        return candidate
    }
}
