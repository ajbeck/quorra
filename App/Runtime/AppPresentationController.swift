import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppPresentationController {
    private(set) var runsInMenuBarOnly: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var interactiveWindows: [ObjectIdentifier: WeakWindow] = [:]
    @ObservationIgnored private var windowObservers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    @ObservationIgnored private var terminationRequested = false

    init(defaults: UserDefaults? = nil) {
        let resolvedDefaults = defaults ?? AppPresentationPreferences.sharedDefaults()
        self.defaults = resolvedDefaults
        runsInMenuBarOnly = resolvedDefaults.bool(forKey: AppPresentationPreferences.menuBarOnlyKey)
    }

    func applyCurrentActivationPolicy() {
        NSApplication.shared.setActivationPolicy(runsInMenuBarOnly ? .accessory : .regular)
    }

    func prepareForInteractivePresentation() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.unhide(nil)
    }

    /// Quits for the explicit Quit paths: the menu bar item, the setup screen, and the CLI.
    func terminate() {
        terminationRequested = true
        NSApplication.shared.terminate(nil)
    }

    /// Whether an incoming quit should close the app's windows instead. True only for a quit
    /// the user issued from a window (⌘Q or the App menu) while the app runs in the menu bar
    /// only. Explicit quits and quits that arrive as Apple events, such as logout, shutdown, the
    /// Dock, AppleScript, and Sparkle's relaunch during an update, always proceed.
    func shouldCloseWindowsInsteadOfTerminating() -> Bool {
        guard runsInMenuBarOnly, !terminationRequested else { return false }
        guard NSAppleEventManager.shared().currentAppleEvent == nil else { return false }
        interactiveWindows = interactiveWindows.filter { $0.value.window != nil }
        return !interactiveWindows.isEmpty
    }

    func closeInteractiveWindows() {
        for entry in interactiveWindows.values {
            entry.window?.performClose(nil)
        }
    }

    func registerInteractiveWindow(_ window: NSWindow) {
        let identifier = ObjectIdentifier(window)
        guard interactiveWindows[identifier] == nil else { return }

        window.hidesOnDeactivate = false
        interactiveWindows[identifier] = WeakWindow(window)

        let becameKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                self.markInteractiveWindowPresented(window)
            }
        }
        let willCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                self.removeInteractiveWindow(window)
                self.reconcileActivationPolicyAfterWindowCloses()
            }
        }
        windowObservers[identifier] = [becameKeyObserver, willCloseObserver]

        if window.isKeyWindow {
            markInteractiveWindowPresented(window)
        }
    }

    func setRunsInMenuBarOnly(_ isEnabled: Bool) {
        guard runsInMenuBarOnly != isEnabled else { return }
        runsInMenuBarOnly = isEnabled
        defaults.set(isEnabled, forKey: AppPresentationPreferences.menuBarOnlyKey)
        reconcileActivationPolicy()
    }

    private func markInteractiveWindowPresented(_ window: NSWindow) {
        let identifier = ObjectIdentifier(window)
        interactiveWindows[identifier]?.wasPresented = true
        prepareForInteractivePresentation()
    }

    private func removeInteractiveWindow(_ window: NSWindow) {
        let identifier = ObjectIdentifier(window)
        interactiveWindows[identifier] = nil
        if let observers = windowObservers.removeValue(forKey: identifier) {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    private func reconcileActivationPolicy() {
        interactiveWindows = interactiveWindows.filter { $0.value.window != nil }
        let hasPresentedWindow = interactiveWindows.values.contains { $0.wasPresented }
        let shouldRunAsAccessory = runsInMenuBarOnly && !hasPresentedWindow
        NSApplication.shared.setActivationPolicy(shouldRunAsAccessory ? .accessory : .regular)
    }

    private func reconcileActivationPolicyAfterWindowCloses() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.reconcileActivationPolicy()
        }
    }

    deinit {
        for observer in windowObservers.values.joined() {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

private final class WeakWindow {
    weak var window: NSWindow?
    var wasPresented = false

    init(_ window: NSWindow) {
        self.window = window
    }
}
