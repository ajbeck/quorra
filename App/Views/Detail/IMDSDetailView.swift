import SwiftUI
import AWSConfigINI
import SwiftData
import QuorraAppLogic

struct IMDSDetailView: View {
    let endpointID: String
    @Environment(ProfilesModel.self) private var profilesModel
    @Environment(CredentialsModel.self) private var credentialsModel
    @Environment(IMDSModel.self) private var imdsModel
    @Environment(\.modelContext) private var modelContext
    @Query private var endpointDefinitions: [IMDSEndpointDefinition]
    @Query(sort: \IMDSEndpointLogEntry.timestamp, order: .reverse) private var endpointLogEntries: [IMDSEndpointLogEntry]
    @State private var isPresentingEndpointEditor = false

    var body: some View {
        if let definition = endpointDefinition,
           let node = profilesModel.findProfile(named: definition.profileName) {
            if node.profile.ssoSession != nil {
                detail(for: node, definition: definition)
            } else {
                ContentUnavailableView("IMDS unavailable", systemImage: "antenna.radiowaves.left.and.right.slash")
            }
        } else {
            ContentUnavailableView("IMDS endpoint not found", systemImage: "questionmark.circle")
        }
    }

    private func detail(for node: ProfileNode, definition: IMDSEndpointDefinition) -> some View {
        let endpointKey = definition.stableIDString
        let state = imdsModel.state(forEndpointID: endpointKey)
        let runtime = imdsModel.runtimeInfo(forEndpointID: endpointKey)
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(for: node, endpointKey: endpointKey, state: state, definition: definition)
                serverStatusPanel(for: node, endpointKey: endpointKey, state: state, runtime: runtime, definition: definition)
                endpointCard(for: state, definition: definition)
                configurationCard(for: state, definition: definition)
                activityCard(for: state, runtime: runtime, endpointKey: endpointKey)
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("IMDS Server")
        .sheet(isPresented: $isPresentingEndpointEditor) {
            IMDSEndpointEditorSheet(
                mode: .edit,
                existingNames: Set(endpointDefinitions.map(\.name)),
                usedPorts: Set(endpointDefinitions.map(\.port)),
                profiles: profilesModel.groups.flatProfiles.map(\.node),
                initialDraft: IMDSEndpointEditorDraft(endpoint: definition)
            ) { draft in
                try saveEndpointDefinition(draft, to: definition, endpointKey: endpointKey)
            }
        }
    }

    private var endpointDefinition: IMDSEndpointDefinition? {
        return endpointDefinitions.first { $0.stableIDString == endpointID }
    }

    private func header(
        for node: ProfileNode,
        endpointKey: String,
        state: IMDSEndpointState,
        definition: IMDSEndpointDefinition
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(definition.name)
                .font(.title.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 16)

            Menu {
                Button {
                    copyToPasteboard(endpointURL(for: state, definition: definition))
                } label: {
                    Label("Copy Endpoint URL", systemImage: "doc.on.doc")
                }

                Divider()

                switch state {
                case .inactive:
                    Button {
                        Task {
                            await startEndpoint(endpointKey: endpointKey, for: node, definition: definition)
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
                            imdsModel.stopEndpoint(forEndpointID: endpointKey)
                            await startEndpoint(endpointKey: endpointKey, for: node, definition: definition)
                        }
                    } label: {
                        Label("Restart Server", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) {
                        imdsModel.stopEndpoint(forEndpointID: endpointKey)
                    } label: {
                        Label("Stop Server", systemImage: "stop.fill")
                    }
                case .failed:
                    Button {
                        Task {
                            await startEndpoint(endpointKey: endpointKey, for: node, definition: definition)
                        }
                    } label: {
                        Label("Retry Server", systemImage: "arrow.clockwise")
                    }
                    Button {
                        imdsModel.stopEndpoint(forEndpointID: endpointKey)
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

    private func serverStatusPanel(
        for node: ProfileNode,
        endpointKey: String,
        state: IMDSEndpointState,
        runtime: IMDSRuntimeInfo?,
        definition: IMDSEndpointDefinition
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                serverSummary(for: node, state: state, runtime: runtime, definition: definition)
                Spacer(minLength: 16)
                serverActions(for: node, endpointKey: endpointKey, state: state, definition: definition)
            }

            VStack(alignment: .leading, spacing: 14) {
                serverSummary(for: node, state: state, runtime: runtime, definition: definition)
                serverActions(for: node, endpointKey: endpointKey, state: state, definition: definition)
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

    private func serverSummary(
        for node: ProfileNode,
        state: IMDSEndpointState,
        runtime: IMDSRuntimeInfo?,
        definition: IMDSEndpointDefinition
    ) -> some View {
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

                Text(endpointURL(for: state, definition: definition))
                    .font(.title3.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Text(statusMetadata(for: state, runtime: runtime, definition: definition))
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

    private func serverActions(
        for node: ProfileNode,
        endpointKey: String,
        state: IMDSEndpointState,
        definition: IMDSEndpointDefinition
    ) -> some View {
        HStack(spacing: 10) {
            switch state {
            case .inactive:
                Button {
                    Task {
                        await startEndpoint(endpointKey: endpointKey, for: node, definition: definition)
                    }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)

            case .starting:
                Button(role: .cancel) {
                    imdsModel.stopEndpoint(forEndpointID: endpointKey)
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .buttonStyle(.bordered)

            case .active:
                Button {
                    Task {
                        imdsModel.stopEndpoint(forEndpointID: endpointKey)
                        await startEndpoint(endpointKey: endpointKey, for: node, definition: definition)
                    }
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    imdsModel.stopEndpoint(forEndpointID: endpointKey)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)

            case .failed:
                Button {
                    Task {
                        await startEndpoint(endpointKey: endpointKey, for: node, definition: definition)
                    }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    imdsModel.stopEndpoint(forEndpointID: endpointKey)
                } label: {
                    Label("Dismiss", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.regular)
    }

    private func startEndpoint(
        endpointKey: String,
        for node: ProfileNode,
        definition: IMDSEndpointDefinition
    ) async {
        await imdsModel.startEndpoint(
            endpointID: endpointKey,
            for: node,
            credentialsModel: credentialsModel,
            port: definition.port,
            requestRecorder: persistRequestLog
        )
    }

    private func endpointCard(for state: IMDSEndpointState, definition: IMDSEndpointDefinition) -> some View {
        let endpoint = endpointURL(for: state, definition: definition)
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

    private func configurationCard(for state: IMDSEndpointState, definition: IMDSEndpointDefinition) -> some View {
        DetailCard("Configuration") {
            HStack {
                Spacer()
                Button {
                    isPresentingEndpointEditor = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Edit endpoint configuration")
            }
            .padding(.bottom, 6)

            DetailField("Port") {
                Text(String(state.port ?? definition.port))
                    .font(.body.monospacedDigit())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
            }

            DetailDivider()

            DetailField("Bind address") {
                Text(definition.bindAddress)
                    .font(.body.monospaced())
            }

            DetailDivider()

            DetailField("IMDS version") {
                Picker("IMDS version", selection: .constant(definition.allowsIMDSv1 ? "v1+v2" : "v2")) {
                    Text("v1").tag("v1")
                    Text("v2").tag("v2")
                    Text("v1 + v2").tag("v1+v2")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 164)
                .disabled(true)
            }

            DetailDivider()

            DetailField("Hop limit") {
                Text(String(definition.hopLimit))
                    .font(.body.monospacedDigit())
            }

            DetailDivider()

            DetailField("Folder") {
                MetadataFolderPicker(
                    objectKind: .imdsEndpoint,
                    objectID: definition.stableIDString,
                    isEnabled: true
                )
                .labelsHidden()
            }
        }
    }

    private func saveEndpointDefinition(
        _ draft: IMDSEndpointEditorDraft,
        to definition: IMDSEndpointDefinition,
        endpointKey: String
    ) throws {
        let runtimeConfigurationChanged = definition.profileName != draft.profileName
            || definition.port != draft.port
            || definition.bindAddress != draft.bindAddress
            || definition.allowsIMDSv1 != draft.allowsIMDSv1
            || definition.hopLimit != draft.hopLimit

        draft.apply(to: definition)
        try modelContext.save()

        if runtimeConfigurationChanged {
            imdsModel.stopEndpoint(forEndpointID: endpointKey)
        }
    }

    private func activityCard(for state: IMDSEndpointState, runtime: IMDSRuntimeInfo?, endpointKey: String) -> some View {
        let events = activityEvents(endpointKey: endpointKey, runtime: runtime)
        return DetailCard("Activity") {
            if !events.isEmpty {
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
                    description: Text("Start the endpoint to see IMDS requests here.")
                )
                .frame(maxWidth: .infinity, minHeight: 92)
            }
        }
    }

    private func activityEvents(endpointKey: String, runtime: IMDSRuntimeInfo?) -> [IMDSRequestLog] {
        let persisted = persistedActivityEvents(endpointKey: endpointKey)
        if !persisted.isEmpty {
            return persisted
        }
        return runtime?.activity ?? []
    }

    private func persistedActivityEvents(endpointKey: String) -> [IMDSRequestLog] {
        guard UUID(uuidString: endpointKey) != nil else { return [] }
        return endpointLogEntries
            .filter { $0.endpointIDString == endpointKey }
            .prefix(IMDSEndpointLogStore.maxEntriesPerEndpoint)
            .map(IMDSRequestLog.init(entry:))
    }

    private func persistRequestLog(endpointID: String, log: IMDSRequestLog) {
        guard let endpointUUID = UUID(uuidString: endpointID) else { return }

        do {
            try IMDSEndpointLogStore.append(
                IMDSEndpointLogEntry(
                    id: log.id,
                    endpointID: endpointUUID,
                    timestamp: log.timestamp,
                    method: log.method,
                    path: log.path,
                    statusCode: log.status,
                    client: log.client
                ),
                in: modelContext
            )
        } catch {
            // Request logging should never interrupt an already-running local endpoint.
        }
    }

    private func endpointURL(for state: IMDSEndpointState, definition: IMDSEndpointDefinition) -> String {
        let bindAddress = definition.bindAddress
        let port = state.port ?? definition.port
        return "http://\(bindAddress):\(port)"
    }

    private func statusTitle(for state: IMDSEndpointState) -> String {
        switch state {
        case .inactive: return "Inactive"
        case .starting: return "Starting"
        case .active: return "Running"
        case .failed: return "Failed"
        }
    }

    private func statusMetadata(
        for state: IMDSEndpointState,
        runtime: IMDSRuntimeInfo?,
        definition: IMDSEndpointDefinition
    ) -> String {
        let bindAddress = definition.bindAddress
        let version = definition.allowsIMDSv1 ? "IMDSv1 + IMDSv2" : "IMDSv2"
        switch state {
        case .inactive:
            return "ready to serve \(version) on \(bindAddress)"
        case .starting:
            return "binding to \(bindAddress) · \(version)"
        case .active:
            if let runtime {
                return "up \(relativeDuration(since: runtime.startedAt)) · \(runtime.requestCount.formatted()) requests served · \(version)"
            }
            return "up 1h 48m · 1,243 requests served · \(version)"
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
    init(entry: IMDSEndpointLogEntry) {
        self.init(
            id: entry.stableID,
            timestamp: entry.timestamp,
            method: entry.method,
            path: entry.path,
            client: entry.client ?? "localhost",
            status: entry.statusCode
        )
    }

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
    IMDSDetailPreviewHarness(state: .inactive)
}

#Preview("IMDS Detail - starting") {
    IMDSDetailPreviewHarness(state: .starting(port: 9678))
}

#Preview("IMDS Detail - active") {
    IMDSDetailPreviewHarness(state: .active(port: 9678))
}

#Preview("IMDS Detail - failed") {
    IMDSDetailPreviewHarness(state: .failed(port: 9678, message: "Port 9678 is already in use."))
}

#Preview("quorra") {
    IMDSDetailPreviewHarness(state: .active(port: 9678))
}

private struct IMDSDetailPreviewHarness: View {
    private static let endpointID = UUID(uuidString: "00000000-0000-0000-0000-000000009678")!

    @State private var model: IMDSModel
    private let metadataContainer: ModelContainer

    init(state: IMDSEndpointState) {
        let metadataContainer = try! QuorraMetadataSchema.makeContainer(inMemory: true)
        let endpoint = IMDSEndpointDefinition(
            id: Self.endpointID,
            name: "localhost:9678",
            profileName: "ac:cp:org_admin",
            port: 9678
        )
        metadataContainer.mainContext.insert(endpoint)
        try! metadataContainer.mainContext.save()

        let model = IMDSModel()
        model.setState(state, forEndpointID: endpoint.stableIDString)

        _model = State(initialValue: model)
        self.metadataContainer = metadataContainer
    }

    var body: some View {
        IMDSDetailView(endpointID: Self.endpointID.uuidString)
        .environment(ProfilesModel.previewLoaded(config: PreviewAWSFixtures.mockupConfig))
        .environment(CredentialsModel(service: PreviewIdentityCenterService()))
        .environment(model)
        .modelContainer(metadataContainer)
        .frame(width: 920, height: 720)
    }
}
