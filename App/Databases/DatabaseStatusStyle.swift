import DatabaseProxy
import SwiftUI

/// How a database connection's state reads in rows, the detail and the menu bar.
extension ProxyEndpointStatus.State {
    var systemImage: String {
        switch self {
        case .stopped: return "circle"
        case .starting, .checkingUpstream: return "circle.dotted"
        case .listening: return "circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .stopped: return .secondary
        case .starting, .checkingUpstream: return .orange
        case .listening: return .green
        case .failed: return .red
        }
    }

    var isRunning: Bool {
        self != .stopped
    }
}
