import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AuthenticationBrowser {
    private(set) var failedURL: URL?

    @ObservationIgnored private let openURL: @MainActor (URL) -> Bool

    init(openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.openURL = openURL
    }

    func open(_ url: URL) {
        guard url.scheme?.lowercased() == "https", openURL(url) else {
            failedURL = url
            return
        }
        failedURL = nil
    }
}

struct AuthenticationBrowserActions: View {
    let verificationURL: URL
    let userCode: String

    @Environment(\.authenticationBrowser) private var authenticationBrowser
    @State private var copiedItem: CopiedItem?
    @State private var resetTask: Task<Void, Never>?

    private enum CopiedItem {
        case code
        case link
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quorra is waiting for AWS until this code expires. If you closed the browser tab, reopen it here or copy the link.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Open browser again") {
                    authenticationBrowser.open(verificationURL)
                }

                Button(copiedItem == .code ? "Copied code" : "Copy code") {
                    copy(userCode, item: .code)
                }

                Button(copiedItem == .link ? "Copied link" : "Copy link") {
                    copy(verificationURL.absoluteString, item: .link)
                }
            }
            .controlSize(.small)

            if authenticationBrowser.failedURL == verificationURL {
                Label(
                    "Quorra couldn't open the default browser. Copy the link and open it manually.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .onDisappear {
            resetTask?.cancel()
            resetTask = nil
        }
    }

    private func copy(_ value: String, item: CopiedItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)

        resetTask?.cancel()
        copiedItem = item
        resetTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            copiedItem = nil
            resetTask = nil
        }
    }
}

private struct AuthenticationBrowserKey: EnvironmentKey {
    static let defaultValue = AuthenticationBrowser()
}

extension EnvironmentValues {
    var authenticationBrowser: AuthenticationBrowser {
        get { self[AuthenticationBrowserKey.self] }
        set { self[AuthenticationBrowserKey.self] = newValue }
    }
}
