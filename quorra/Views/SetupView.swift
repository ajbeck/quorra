import AppKit
import SwiftUI

struct SetupView: View {
    @Environment(AppModel.self) private var appModel
    @State private var pendingFolder: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            pathField
            Spacer(minLength: 0)
            buttonRow
        }
        .padding(.horizontal, 40)
        .padding(.top, 44)
        .padding(.bottom, 24)
        .frame(minWidth: 560, minHeight: 460)
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

            (Text("Quorra will read ")
             + monoInline("config")
             + Text(" and ")
             + monoInline("credentials")
             + Text(", and store new secrets in the macOS Keychain."))
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

    private func monoInline(_ text: String) -> Text {
        Text(text).font(.system(size: 11, design: .monospaced))
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
        // Sandbox requires user confirmation via NSOpenPanel, so "Continue" still
        // opens the picker — but pre-filled at ~/.aws so the user simply confirms.
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
}

#Preview("Setup") {
    SetupView()
        .environment(AppModel(initialPhase: .setup))
}
