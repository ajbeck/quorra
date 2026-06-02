import SwiftUI
import AWSConfigINI

struct IMDSDetailView: View {
    let profileName: String
    @Environment(ProfilesModel.self) private var profilesModel
    @Environment(CredentialsModel.self) private var credentialsModel
    @Environment(IMDSModel.self) private var imdsModel

    var body: some View {
        if let node = profilesModel.findProfile(named: profileName) {
            if node.profile.ssoSession != nil {
                detail(for: node)
            } else {
                ContentUnavailableView("IMDS unavailable", systemImage: "antenna.radiowaves.left.and.right.slash")
            }
        } else {
            ContentUnavailableView("IMDS endpoint not found", systemImage: "questionmark.circle")
        }
    }

    private func detail(for node: ProfileNode) -> some View {
        let state = imdsModel.state(forProfile: node.id)
        let runtime = imdsModel.runtimeInfo(forProfile: node.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(for: node, state: state)
                serverStatusPanel(for: node, state: state, runtime: runtime)
                endpointCard(for: state)
                configurationCard(for: state)
                activityCard(for: state, runtime: runtime)
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("IMDS Server")
    }

    private func header(for node: ProfileNode, state: IMDSEndpointState) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("IMDS Server")
                .font(.title.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 16)

            Menu {
                Button {
                    copyToPasteboard(endpointURL(for: state))
                } label: {
                    Label("Copy Endpoint URL", systemImage: "doc.on.doc")
                }

                Divider()

                switch state {
                case .inactive:
                    Button {
                        Task {
                            await imdsModel.startEndpoint(for: node, credentialsModel: credentialsModel)
                        }
                    } label: {
                        Label("Start Server", systemImage: "play.fill")
                    }
                case .starting:
                    Button("Starting Server") {}
                        .disabled(true)
                case .active:
                    Button {
                        Task {
                            await imdsModel.restartEndpoint(for: node, credentialsModel: credentialsModel)
                        }
                    } label: {
                        Label("Restart Server", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) {
                        imdsModel.stopEndpoint(forProfile: profileName)
                    } label: {
                        Label("Stop Server", systemImage: "stop.fill")
                    }
                case .failed:
                    Button {
                        Task {
                            await imdsModel.retryEndpoint(for: node, credentialsModel: credentialsModel)
                        }
                    } label: {
                        Label("Retry Server", systemImage: "arrow.clockwise")
                    }
                    Button {
                        imdsModel.stopEndpoint(forProfile: profileName)
                    } label: {
                        Label("Dismiss Failure", systemImage: "xmark")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .foregroundStyle(.secondary)
            .help("More actions")
        }
    }

    private func serverStatusPanel(for node: ProfileNode, state: IMDSEndpointState, runtime: IMDSRuntimeInfo?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                serverSummary(for: node, state: state, runtime: runtime)
                Spacer(minLength: 16)
                serverActions(for: node, state: state)
            }

            VStack(alignment: .leading, spacing: 14) {
                serverSummary(for: node, state: state, runtime: runtime)
                serverActions(for: node, state: state)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(16)
        .background(statusAccent(for: state).opacity(state.isActive ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(statusAccent(for: state).opacity(state.isActive || state.isFailed ? 0.28 : 0.1))
        }
    }

    private func serverSummary(for node: ProfileNode, state: IMDSEndpointState, runtime: IMDSRuntimeInfo?) -> some View {
        HStack(spacing: 14) {
            statusIcon(for: state)
                .frame(width: 34, height: 34)
                .background(statusAccent(for: state).opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    IMDSStatusBadge(title: statusTitle(for: state), color: statusAccent(for: state))
                    if state.port != nil {
                        IMDSStatusBadge(title: "serving \(node.id)", color: .blue)
                    }
                }

                Text(endpointURL(for: state))
                    .font(.title3.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Text(statusMetadata(for: state, runtime: runtime))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func statusIcon(for state: IMDSEndpointState) -> some View {
        switch state {
        case .inactive:
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
        case .starting:
            ProgressView()
                .controlSize(.small)
        case .active:
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func serverActions(for node: ProfileNode, state: IMDSEndpointState) -> some View {
        HStack(spacing: 10) {
            switch state {
            case .inactive:
                Button {
                    Task {
                        await imdsModel.startEndpoint(for: node, credentialsModel: credentialsModel)
                    }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)

            case .starting:
                Button(role: .cancel) {
                    imdsModel.stopEndpoint(forProfile: profileName)
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .buttonStyle(.bordered)

            case .active:
                Button {
                    Task {
                        await imdsModel.restartEndpoint(for: node, credentialsModel: credentialsModel)
                    }
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    imdsModel.stopEndpoint(forProfile: profileName)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)

            case .failed:
                Button {
                    Task {
                        await imdsModel.retryEndpoint(for: node, credentialsModel: credentialsModel)
                    }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    imdsModel.stopEndpoint(forProfile: profileName)
                } label: {
                    Label("Dismiss", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.regular)
    }

    private func endpointCard(for state: IMDSEndpointState) -> some View {
        let endpoint = endpointURL(for: state)
        return DetailCard("Endpoint") {
            VStack(alignment: .leading, spacing: 10) {
                commandLineRow(prefix: "URL", value: endpoint)
                commandLineRow(
                    prefix: "$",
                    value: "export AWS_EC2_METADATA_SERVICE_ENDPOINT=\(endpoint)"
                )
                commandLineRow(
                    prefix: "$",
                    value: "curl \(endpoint)/latest/meta-data/iam/security-credentials/"
                )
            }
        }
    }

    private func commandLineRow(prefix: String, value: String) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(prefix)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 34, alignment: .leading)
                Text(value)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.callout.monospaced())
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(Color.black.opacity(0.28))

            Button {
                copyToPasteboard(value)
            } label: {
                ViewThatFits(in: .horizontal) {
                    Label("Copy", systemImage: "doc.on.doc")
                    Image(systemName: "doc.on.doc")
                }
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 36)
            .help("Copy")
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.08))
        }
    }

    private func configurationCard(for state: IMDSEndpointState) -> some View {
        DetailCard("Configuration") {
            DetailField("Port") {
                Text(String(state.port ?? 9678))
                    .font(.body.monospacedDigit())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
            }

            DetailDivider()

            DetailField("Bind address") {
                Text("127.0.0.1")
                    .font(.body.monospaced())
            }

            DetailDivider()

            DetailField("IMDS version") {
                Picker("IMDS version", selection: .constant("v2")) {
                    Text("v1").tag("v1")
                    Text("v2").tag("v2")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 108)
                .disabled(true)
            }

            DetailDivider()

            DetailField("Hop limit") {
                Text("2")
                    .font(.body.monospacedDigit())
            }
        }
    }

    private func activityCard(for state: IMDSEndpointState, runtime: IMDSRuntimeInfo?) -> some View {
        let events = runtime?.activity ?? IMDSRequestLog.previewEvents
        return DetailCard("Activity") {
            if state.isActive, !events.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(events) { event in
                        IMDSActivityRow(event: event)
                        if event.id != events.last?.id {
                            Divider()
                                .padding(.leading, 118)
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    state.isActive ? "No Requests Yet" : "No Requests",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Start the endpoint to see IMDS requests.")
                )
                .frame(maxWidth: .infinity, minHeight: 92)
            }
        }
    }

    private func endpointURL(for state: IMDSEndpointState) -> String {
        "http://127.0.0.1:\(state.port ?? 9678)"
    }

    private func statusTitle(for state: IMDSEndpointState) -> String {
        switch state {
        case .inactive: return "Inactive"
        case .starting: return "Starting"
        case .active: return "Running"
        case .failed: return "Failed"
        }
    }

    private func statusMetadata(for state: IMDSEndpointState, runtime: IMDSRuntimeInfo?) -> String {
        switch state {
        case .inactive:
            return "ready to serve IMDSv2 on 127.0.0.1"
        case .starting:
            return "binding to 127.0.0.1 · IMDSv2"
        case .active:
            if let runtime {
                return "up \(relativeDuration(since: runtime.startedAt)) · \(runtime.requestCount.formatted()) requests served · IMDSv2"
            }
            return "up 1h 48m · 1,243 requests served · IMDSv2"
        case .failed(_, let message):
            return message
        }
    }

    private func relativeDuration(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    private func statusAccent(for state: IMDSEndpointState) -> Color {
        switch state {
        case .inactive:
            return .secondary
        case .starting:
            return .blue
        case .active:
            return .green
        case .failed:
            return .orange
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct IMDSStatusBadge: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.16), in: Capsule())
    }
}

private extension IMDSRequestLog {
    static let previewEvents: [IMDSRequestLog] = [
        IMDSRequestLog(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            timestamp: Date().addingTimeInterval(-3),
            method: "GET",
            path: "/latest/meta-data/iam/security-credentials/",
            client: "terraform",
            status: 200
        ),
        IMDSRequestLog(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            timestamp: Date().addingTimeInterval(-3),
            method: "GET",
            path: "/latest/meta-data/iam/security-credentials/OrganizationAdmin",
            client: "terraform",
            status: 200
        ),
        IMDSRequestLog(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            timestamp: Date().addingTimeInterval(-6),
            method: "PUT",
            path: "/latest/api/token",
            client: "boto3",
            status: 200
        )
    ]
}

private struct IMDSActivityRow: View {
    let event: IMDSRequestLog

    var body: some View {
        HStack(spacing: 14) {
            Text(event.timestamp, format: .dateTime.hour().minute().second())
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)

            Text(event.method)
                .font(.callout.monospaced().weight(.semibold))
                .foregroundStyle(methodColor)
                .frame(width: 42, alignment: .leading)

            Text(event.path)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            Text(event.client)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(String(event.status))
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.green)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }

    private var methodColor: Color {
        event.method == "PUT" ? .orange : .blue
    }
}

#Preview("IMDS Detail - inactive") {
    IMDSDetailView(profileName: "ac:cp:org_admin")
        .environment(ProfilesModel.previewLoaded(config: PreviewAWSFixtures.mockupConfig))
        .environment(CredentialsModel(service: PreviewIdentityCenterService()))
        .environment(IMDSModel())
}

#Preview("IMDS Detail - starting") {
    let model = IMDSModel()
    model.setState(.starting(port: 9678), forProfile: "ac:cp:org_admin")
    return IMDSDetailView(profileName: "ac:cp:org_admin")
        .environment(ProfilesModel.previewLoaded(config: PreviewAWSFixtures.mockupConfig))
        .environment(CredentialsModel(service: PreviewIdentityCenterService()))
        .environment(model)
}

#Preview("IMDS Detail - active") {
    let model = IMDSModel()
    model.setState(.active(port: 9678), forProfile: "ac:cp:org_admin")
    return IMDSDetailView(profileName: "ac:cp:org_admin")
        .environment(ProfilesModel.previewLoaded(config: PreviewAWSFixtures.mockupConfig))
        .environment(CredentialsModel(service: PreviewIdentityCenterService()))
        .environment(model)
}

#Preview("IMDS Detail - failed") {
    let model = IMDSModel()
    model.setState(.failed(port: 9678, message: "Port 9678 is already in use."), forProfile: "ac:cp:org_admin")
    return IMDSDetailView(profileName: "ac:cp:org_admin")
        .environment(ProfilesModel.previewLoaded(config: PreviewAWSFixtures.mockupConfig))
        .environment(CredentialsModel(service: PreviewIdentityCenterService()))
        .environment(model)
}
