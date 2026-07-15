import AppKit
import SwiftUI
import AWSConfigINI
import QuorraAppLogic

struct SetupView: View {
    @Environment(AppModel.self) private var appModel
    @State private var pendingFolder: URL?
    @State private var selectedMode: ManagedMode = .managed

    /// Preview-only seed for warning and mode-card states.
    init(previewPendingFolder: URL? = nil, previewSelectedMode: ManagedMode = .managed) {
        _pendingFolder = State(initialValue: previewPendingFolder)
        _selectedMode = State(initialValue: previewSelectedMode)
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

            modeCard
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

    private var pathField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AWS FOLDER")
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(0.06 * 11.5)
                .foregroundStyle(.secondary)

            Text("Defaults to `~/.aws`, the standard AWS CLI location.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(cardBackground(isSelected: false))
    }

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HOW SHOULD QUORRA MANAGE THIS FOLDER?")
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(0.06 * 11.5)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                modeOption(
                    .managed,
                    title: "Edit & Manage",
                    blurb: "Quorra can add, edit, and reformat profiles in your AWS files. A `# Managed by Quorra` header is added on first save.",
                    isRecommended: true
                )
                modeOption(
                    .readOnly,
                    title: "Read Only",
                    blurb: "Quorra reads your profiles and serves credentials, but never writes to your AWS files. Choose this if you hand-edit them.",
                    isRecommended: false
                )
            }
        }
    }

    private func modeOption(_ mode: ManagedMode, title: String, blurb: String, isRecommended: Bool) -> some View {
        let isSelected = selectedMode == mode
        return Button { selectedMode = mode } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? Theme.accent : .secondary)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    if isRecommended {
                        Text("recommended")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Theme.accent.opacity(0.18)))
                    }
                }
                Text(blurb)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isRecommended ? "\(title). Recommended." : title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func cardBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Theme.accent.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? Theme.accent.opacity(0.5) : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 1 : 0.5
                    )
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
        HStack(spacing: 10) {
            Button("Cancel") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut(.cancelAction)

            Button("Choose AWS Folder…") {
                Task { await chooseAWSFolder() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Actions

    private func chooseAWSFolder() async {
        await runPicker()
    }

    private func runPicker() async {
        guard let picked = await FolderPicker.pickAWSFolder() else { return }

        if picked.standardizedFileURL == UserHome.awsFolder.standardizedFileURL {
            await appModel.completeSetup(selectedFolder: picked, mode: selectedMode)
        } else {
            pendingFolder = picked
        }
    }

    private func confirmPendingFolder() async {
        guard let folder = pendingFolder else { return }
        await appModel.completeSetup(selectedFolder: folder, mode: selectedMode)
    }
}

#Preview("Setup – idle (managed)") {
    SetupView()
        .environment(AppModel(initialPhase: .setup))
}

#Preview("Setup – read-only selected") {
    SetupView(previewSelectedMode: .readOnly)
        .environment(AppModel(initialPhase: .setup))
}

#Preview("Setup – non-standard warning") {
    SetupView(previewPendingFolder: URL(filePath: "/Users/jordan/work/aws-config"))
        .environment(AppModel(initialPhase: .setup))
}
