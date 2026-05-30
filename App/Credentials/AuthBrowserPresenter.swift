import AppKit
import AuthenticationServices
import SwiftUI

@MainActor
final class AuthBrowserPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func present(_ url: URL) {
        dismiss()

        let authSession = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, _ in
            Task { @MainActor in
                self?.session = nil
            }
        }
        authSession.presentationContextProvider = self
        authSession.prefersEphemeralWebBrowserSession = false

        session = authSession
        if !authSession.start() {
            session = nil
            NSWorkspace.shared.open(url)
        }
    }

    func dismiss() {
        session?.cancel()
        session = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { currentPresentationAnchor() }
        }

        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { currentPresentationAnchor() }
        }
    }

    @MainActor private func currentPresentationAnchor() -> ASPresentationAnchor {
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first
            ?? NSWindow()
    }
}

private struct AuthBrowserPresenterKey: EnvironmentKey {
    static let defaultValue = AuthBrowserPresenter()
}

extension EnvironmentValues {
    var authBrowserPresenter: AuthBrowserPresenter {
        get { self[AuthBrowserPresenterKey.self] }
        set { self[AuthBrowserPresenterKey.self] = newValue }
    }
}
