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
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".aws")
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
}
