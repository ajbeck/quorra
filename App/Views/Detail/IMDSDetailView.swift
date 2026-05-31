import SwiftUI
import AWSConfigINI

struct IMDSDetailView: View {
    let profileName: String
    @Environment(ProfilesModel.self) private var profilesModel
    @Environment(IMDSModel.self) private var imdsModel

    var body: some View {
        guard let node = profilesModel.findProfile(named: profileName) else {
            return AnyView(ContentUnavailableView("IMDS endpoint not found", systemImage: "questionmark.circle"))
        }

        guard node.profile.ssoSession != nil else {
            return AnyView(ContentUnavailableView("IMDS unavailable", systemImage: "antenna.radiowaves.left.and.right.slash"))
        }

        return AnyView(detail(for: node))
    }

    private func detail(for node: ProfileNode) -> some View {
        let state = imdsModel.state(forProfile: node.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(node.id)
                        .font(.title.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 16)
                }

                GroupBox("IMDS endpoint") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            LabeledContent("Status", value: statusText(for: state))
                            Spacer(minLength: 16)
                            Toggle("Enabled", isOn: .constant(state.isActive))
                                .labelsHidden()
                                .disabled(true)
                        }

                        Divider()

                        LabeledContent("Endpoint") {
                            Text(endpointText(for: state))
                                .font(.body.monospaced())
                                .foregroundStyle(state.isActive ? .primary : .secondary)
                                .textSelection(.enabled)
                        }

                        LabeledContent("Session", value: node.profile.ssoSession ?? "—")
                        LabeledContent("Account ID", value: node.profile.ssoAccountId ?? "—")
                        LabeledContent("Role", value: node.profile.ssoRoleName ?? "—")
                        LabeledContent("Region", value: node.profile.region ?? "—")
                        if let failureMessage = state.failureMessage {
                            LabeledContent("Error", value: failureMessage)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("")
    }

    private func statusText(for state: IMDSEndpointState) -> String {
        switch state {
        case .inactive: return "Inactive"
        case .starting: return "Starting"
        case .active: return "Serving"
        case .failed: return "Failed"
        }
    }

    private func endpointText(for state: IMDSEndpointState) -> String {
        switch state {
        case .inactive: return "Not running"
        case .starting(let port), .active(let port), .failed(let port, _):
            return "http://127.0.0.1:\(port)"
        }
    }
}

#Preview("IMDS Detail – inactive") {
    IMDSDetailView(profileName: "ac:cp:org_admin")
        .environment(ProfilesModel.previewLoaded(config: PreviewAWSFixtures.mockupConfig))
        .environment(IMDSModel())
}

#Preview("IMDS Detail – active") {
    let model = IMDSModel()
    model.setState(.active(port: 9678), forProfile: "ac:cp:org_admin")
    return IMDSDetailView(profileName: "ac:cp:org_admin")
        .environment(ProfilesModel.previewLoaded(config: PreviewAWSFixtures.mockupConfig))
        .environment(model)
}

#Preview("IMDS Detail – failed") {
    let model = IMDSModel()
    model.setState(.failed(port: 9678, message: "Port 9678 is already in use."), forProfile: "ac:cp:org_admin")
    return IMDSDetailView(profileName: "ac:cp:org_admin")
        .environment(ProfilesModel.previewLoaded(config: PreviewAWSFixtures.mockupConfig))
        .environment(model)
}
