import AppKit
import QuorraAppLogic
import SwiftUI

struct ErrorView: View {
    @Environment(AppModel.self) private var appModel
    let error: AppError

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)

            icon
                .padding(.bottom, 2)

            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .multilineTextAlignment(.center)

            detail
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)

            actionRow
                .padding(.top, 4)

            if case .bookmarkResolutionFailed(let underlying) = error {
                diagnosticDisclosure(for: underlying)
                    .padding(.top, 6)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 32)
        .frame(minWidth: 520, minHeight: 360)
    }

    // MARK: - Per-case content

    private var icon: some View {
        Group {
            switch error {
            case .folderMissing:
                Image(systemName: "folder")
                    .font(.system(size: 48, weight: .regular))
                    .foregroundStyle(.secondary)
            case .folderAccessDenied:
                Image(systemName: "nosign")
                    .font(.system(size: 48, weight: .regular))
                    .foregroundStyle(Theme.danger)
            case .bookmarkResolutionFailed:
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 48, weight: .regular))
                    .foregroundStyle(Theme.warn)
            }
        }
    }

    private var title: String {
        switch error {
        case .folderMissing:          return "Your AWS folder moved"
        case .folderAccessDenied:     return "macOS blocked access to that folder"
        case .bookmarkResolutionFailed: return "Couldn't open your saved folder"
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch error {
        case .folderMissing:
            Text("The folder Quorra was using isn't where it used to be. Pick its new location to continue.")
        case .folderAccessDenied:
            Text("The system refused permission to use the folder Quorra had saved. This usually means the bookmark went stale after an update — re-granting access fixes it.")
        case .bookmarkResolutionFailed:
            Text("Quorra's bookmark to your AWS folder couldn't be resolved. This is rare — usually a code-signing change or disk repair. You can pick the folder again to recover.")
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 10) {
            switch error {
            case .folderMissing:
                Button {
                    Task { await runPicker() }
                } label: {
                    Label("Choose AWS Folder…", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)

                Button("Try Again") {
                    Task { await appModel.retryResolution() }
                }

            case .folderAccessDenied:
                Button {
                    Task { await runPicker() }
                } label: {
                    Label("Re-grant Access…", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)

            case .bookmarkResolutionFailed:
                Button {
                    Task { await runPicker() }
                } label: {
                    Label("Choose AWS Folder…", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func diagnosticDisclosure(for underlying: any Error) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                diagnosticRow("Domain", (underlying as NSError).domain)
                diagnosticRow("Code", String((underlying as NSError).code))
                diagnosticRow("Message", underlying.localizedDescription)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Technical details")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 380)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    private func diagnosticRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(nil)
        }
    }

    // MARK: - Actions

    private func runPicker() async {
        guard let picked = await FolderPicker.pickAWSFolder() else { return }
        await appModel.completeSetup(selectedFolder: picked, mode: appModel.mode)
    }
}

// MARK: - Previews

#if DEBUG

#Preview("Error – folderMissing") {
    ErrorView(error: .folderMissing)
        .environment(AppModel(initialPhase: .error(.folderMissing)))
}

#Preview("Error – folderAccessDenied") {
    ErrorView(error: .folderAccessDenied)
        .environment(AppModel(initialPhase: .error(.folderAccessDenied)))
}

#Preview("Error – bookmarkResolutionFailed") {
    let underlying = NSError(
        domain: NSCocoaErrorDomain,
        code: 4864,
        userInfo: [NSLocalizedDescriptionKey: "The data couldn't be read because it isn't in the correct format."]
    )
    return ErrorView(error: .bookmarkResolutionFailed(underlying: underlying))
        .environment(AppModel(initialPhase: .error(.bookmarkResolutionFailed(underlying: underlying))))
}

#endif
