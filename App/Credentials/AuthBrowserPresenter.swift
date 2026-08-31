import AppKit
import Observation
import SwiftUI
import WebKit

@MainActor
final class AuthBrowserPresenter: NSObject, NSWindowDelegate {
    private var windowController: NSWindowController?
    private var browserState: AuthBrowserState?

    func present(_ url: URL) {
        guard url.scheme == "https" else {
            NSWorkspace.shared.open(url)
            return
        }

        if let windowController, let browserState {
            browserState.load(url)
            show(windowController)
            return
        }

        let browserState = AuthBrowserState(verificationURL: url)
        let hostingController = NSHostingController(rootView: AuthBrowserView(state: browserState))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Sign in to IAM Identity Center"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 980, height: 720))
        window.minSize = NSSize(width: 720, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let windowController = NSWindowController(window: window)
        self.browserState = browserState
        self.windowController = windowController
        show(windowController)
    }

    func dismiss() {
        windowController?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === windowController?.window else { return }
        windowController = nil
        browserState = nil
    }

    private func show(_ windowController: NSWindowController) {
        NSApplication.shared.activate()
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
@Observable
private final class AuthBrowserState {
    var verificationURL: URL
    var currentURL: URL
    var isLoading = true
    var canGoBack = false
    var failureDescription: String?

    @ObservationIgnored weak var webView: WKWebView?

    init(verificationURL: URL) {
        self.verificationURL = verificationURL
        self.currentURL = verificationURL
    }

    var currentHost: String {
        currentURL.host(percentEncoded: false)
            ?? verificationURL.host(percentEncoded: false)
            ?? "Unknown host"
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
        webView.load(URLRequest(url: verificationURL))
    }

    func load(_ url: URL) {
        verificationURL = url
        currentURL = url
        failureDescription = nil
        isLoading = true
        webView?.load(URLRequest(url: url))
    }

    func goBack() {
        webView?.goBack()
    }

    func reload() {
        failureDescription = nil
        isLoading = true
        if webView?.url == nil {
            webView?.load(URLRequest(url: verificationURL))
        } else {
            webView?.reload()
        }
    }

    func openInDefaultBrowser() {
        NSWorkspace.shared.open(verificationURL)
    }

    func updateNavigationState(from webView: WKWebView) {
        if let url = webView.url {
            currentURL = url
        }
        canGoBack = webView.canGoBack
    }
}

private struct AuthBrowserView: View {
    @Bindable var state: AuthBrowserState

    var body: some View {
        VStack(spacing: 0) {
            trustStrip
            Divider()
            browserContent
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private var trustStrip: some View {
        HStack(spacing: 10) {
            Button {
                state.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(!state.canGoBack)
            .help("Go back")

            Button {
                state.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reload")

            Divider()
                .frame(height: 18)

            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Secure connection")

            VStack(alignment: .leading, spacing: 1) {
                Text("IAM Identity Center sign-in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(state.currentHost)
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)

            if state.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading sign-in page")
            }

            Button {
                state.openInDefaultBrowser()
            } label: {
                Label("Open in Default Browser", systemImage: "arrow.up.right.square")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    @ViewBuilder
    private var browserContent: some View {
        ZStack {
            AuthWebView(state: state)

            if let failureDescription = state.failureDescription {
                ContentUnavailableView {
                    Label("Sign-in page unavailable", systemImage: "network.slash")
                } description: {
                    Text(failureDescription)
                } actions: {
                    HStack {
                        Button("Try Again") {
                            state.reload()
                        }
                        Button("Open in Default Browser") {
                            state.openInDefaultBrowser()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
            }
        }
    }
}

private struct AuthWebView: NSViewRepresentable {
    let state: AuthBrowserState

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = true
        state.attach(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let state: AuthBrowserState

        init(state: AuthBrowserState) {
            self.state = state
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            switch url.scheme?.lowercased() {
            case "https", "about":
                state.currentURL = url
                decisionHandler(.allow)
            default:
                if navigationAction.navigationType == .linkActivated {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            state.failureDescription = nil
            state.isLoading = true
            state.updateNavigationState(from: webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
            state.updateNavigationState(from: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            state.isLoading = false
            state.updateNavigationState(from: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
            recordFailure(error, webView: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: any Error
        ) {
            recordFailure(error, webView: webView)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil,
                  let url = navigationAction.request.url else {
                return nil
            }
            webView.load(URLRequest(url: url))
            return nil
        }

        private func recordFailure(_ error: any Error, webView: WKWebView) {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
            state.isLoading = false
            state.failureDescription = error.localizedDescription
            state.updateNavigationState(from: webView)
        }
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

#if DEBUG

#Preview("IAM Identity Center browser") {
    AuthBrowserView(
        state: AuthBrowserState(
            verificationURL: URL(string: "https://device.sso.us-east-1.amazonaws.com/")!
        )
    )
    .frame(width: 980, height: 720)
}

#endif
