import Foundation

enum AppError: Error {
    case bookmarkResolutionFailed(underlying: any Error)
    case folderAccessDenied
    case folderMissing
}
