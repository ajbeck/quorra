import Darwin
import Dispatch
import Synchronization

/// Turns SIGINT, SIGTERM and SIGHUP into an `Interrupted` error at the next safe point.
///
/// A signal stops the current child with SIGTERM.
/// The main thread then throws from `Shell` and runs its own cleanup,
/// so cleanup never races the work that it undoes.
public enum Signals {
    enum Phase: Equatable {
        case running
        case cancelled(Int32)
        case finishing
    }

    struct State {
        var phase = Phase.running
        var child: pid_t?
    }

    static let state = Mutex(State())
    nonisolated(unsafe) private static var sources: [any DispatchSourceSignal] = []

    /// Call on the main thread before the first child starts.
    /// A second call has no effect.
    public static func install() {
        guard sources.isEmpty else { return }
        for (number, status) in [(SIGINT, Int32(130)), (SIGTERM, Int32(143)), (SIGHUP, Int32(129))] {
            // Dispatch sources need the default action disabled.
            // `Shell` restores the default action in each child.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { cancel(status) }
            source.resume()
            sources.append(source)
        }
    }

    static func cancel(_ status: Int32) {
        state.withLock { state in
            guard state.phase == .running else { return }
            state.phase = .cancelled(status)
            if let child = state.child { kill(child, SIGTERM) }
        }
    }

    /// Throws when a signal arrived and cleanup has not started.
    public static func checkpoint() throws {
        if case .cancelled(let status) = state.withLock({ $0.phase }) { throw Interrupted(status: status) }
    }

    /// Starts cleanup and returns the status of a pending signal.
    /// Signals that arrive after this call are ignored, as with `trap '' INT TERM HUP`.
    @discardableResult
    public static func finish() -> Int32? {
        state.withLock { state in
            defer { state.phase = .finishing }
            if case .cancelled(let status) = state.phase { return status }
            return nil
        }
    }
}
