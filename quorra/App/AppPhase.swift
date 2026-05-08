import Foundation

enum AppPhase {
    case setup
    case ready(URL)
    case error(AppError)
}
