import AppKit
import SwiftUI

struct SetupView: View {
    @Environment(AppModel.self) private var appModel
    @State private var pendingFolder: URL?

    /// Preview-only seed for the non-standard-folder warning state.
    init(previewPendingFolder: URL? = nil) {
        _pendingFolder = State(initialValue: previewPendingFolder)
    }

    private var isWarningShown: Bool { pendingFolder != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header

            if let pending = pendingFolder {
                nonStandardWarning(for: pending)
            }

            pathField
                .opacity(isWarningShown ? 0.5 : 1)
                .disabled(isWarningShown)

            Spacer(minLength: 0)

            buttonRow
                .opacity(isWarningShown ? 0.5 : 1)
                .disabled(isWarningShown)
        }
        .padding(.horizontal, 40)
        .padding(.top, 44)
        .padding(.bottom, 24)
        .frame(minWidth: 560, minHeight: 460)
        .animation(.easeInOut(duration: 0.18), value: isWarningShown)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set up Quorra")
                .font(.system(size: 22, weight: .semibold))
            Text("Quorra needs access to your AWS configuration folder to read profiles and write changes.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Path field

    private var pathField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AWS FOLDER")
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(0.06 * 11.5)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Text("~/.aws")
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))

                Text("→ \(UserHome.awsFolder.path(percentEncoded: false))")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                Button("Change…") {
                    Task { await changeFolder() }
                }
                .controlSize(.small)
            }

            Divider()

            Text("Quorra will read `config` and `credentials`, and store new secrets in the macOS Keychain.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
    }

    // MARK: - Non-standard folder warning

    private func nonStandardWarning(for folder: URL) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.warn)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 6) {
                Text("Heads up — that's not the standard location")
                    .font(.system(size: 13, weight: .semibold))

                Text("You picked `\(folder.path(percentEncoded: false))`. AWS SDKs read `~/.aws` unless `AWS_CONFIG_FILE` points elsewhere.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Continue with this folder") {
                        Task { await confirmPendingFolder() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Choose Another…") {
                        Task {
                            pendingFolder = nil
                            await runPicker()
                        }
                    }
                    .controlSize(.small)

                    Button("Cancel") {
                        pendingFolder = nil
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(warningBackground)
    }

    private var warningBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Theme.warn.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.warn.opacity(0.4), lineWidth: 0.5)
            )
    }

    // MARK: - Button row

    private var buttonRow: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 10) {
                Button("Cancel") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut(.cancelAction)

                Button("Continue") {
                    Task { await continueWithDefault() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }

            Text("macOS will ask you to confirm access.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Actions

    private func continueWithDefault() async {
        await runPicker()
    }

    private func changeFolder() async {
        await runPicker()
    }

    private func runPicker() async {
        guard let picked = await FolderPicker.pickAWSFolder() else { return }

        if picked.standardizedFileURL == UserHome.awsFolder.standardizedFileURL {
            await appModel.completeSetup(selectedFolder: picked)
        } else {
            pendingFolder = picked
        }
    }

    private func confirmPendingFolder() async {
        guard let folder = pendingFolder else { return }
        await appModel.completeSetup(selectedFolder: folder)
    }
}

#Preview("Setup – idle") {
    SetupView()
        .environment(AppModel(initialPhase: .setup))
}

#Preview("Setup – non-standard warning") {
    SetupView(previewPendingFolder: URL(filePath: "/Users/jordan/work/aws-config"))
        .environment(AppModel(initialPhase: .setup))
}
