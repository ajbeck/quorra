import SwiftUI
import AWSConfigINI
import IAMIdentityCenter
import SwiftData
import QuorraAppLogic

@MainActor
struct IMDSDetailView: View {
    let endpointID: String
    @Binding var detailSelection: DetailSelection?
    @Binding var sourceSelection: SourceSelection
    @Binding var searchText: String
    @Environment(ProfilesModel.self) private var profilesModel
    @Environment(CredentialsModel.self) private var credentialsModel
    @Environment(IMDSModel.self) private var imdsModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var endpointDefinitions: [IMDSEndpointDefinition]
    @State private var isPresentingEndpointEditor = false

    private enum EndpointCredentialState: Equatable {
        case checking
        case signingIn
        case needsSignIn(sessionName: String)
        case ready
        case unavailable
    }

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
                header(for: definition)
                serverStatusPanel(for: node, endpointKey: endpointKey, state: state, runtime: runtime, definition: definition)
                endpointCard(for: state, definition: definition)
                configurationCard(for: state, definition: definition)
                IMDSActivityCard(state: state, runtime: runtime, endpointID: endpointKey)
                    .id(endpointKey)
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("IMDS Server")
        .task(id: credentialKey(for: node)) {
            guard let coordinates = credentialCoordinates(for: node) else { return }
            await credentialsModel.observeStatus(forSession: coordinates.session)
            await credentialsModel.observeProfileStatus(
                forSession: coordinates.session,
                accountId: coordinates.account,
                roleName: coordinates.role
            )
        }
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

    private func header(for definition: IMDSEndpointDefinition) -> some View {
        Text(definition.name)
            .font(.title.weight(.semibold))
            .lineLimit(1)
    }

    private func serverStatusPanel(
        for node: ProfileNode,
        endpointKey: String,
        state: IMDSEndpointState,
        runtime: IMDSRuntimeInfo?,
        definition: IMDSEndpointDefinition
    ) -> some View {
        HStack(spacing: 16) {
            serverSummary(for: node, state: state, runtime: runtime, definition: definition)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            serverActions(for: node, endpointKey: endpointKey, state: state, definition: definition)
        }
        .padding(16)
        .background(statusAccent(for: state).opacity(state.isActive ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(statusAccent(for: state).opacity(state.isActive || state.isFailed ? 0.28 : 0.1))
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: state)
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
                    IMDSStatusBadge(
                        title: statusTitle(for: state),
                        color: statusAccent(for: state),
                        minimumWidth: 72
                    )

                    Button {
                        navigateToProfile(node.id)
                    } label: {
                        Label(node.id, systemImage: "person.crop.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.blue)
                    .pressFeedback()
                    .help("Open profile \(node.id)")
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

                if let prompt = credentialPrompt(for: node, state: state) {
                    Label(prompt, systemImage: "person.badge.key")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
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
            primaryServerAction(
                for: node,
                endpointKey: endpointKey,
                state: state,
                definition: definition
            )
            .frame(width: 100, alignment: .trailing)

            secondaryServerAction(
                for: node,
                endpointKey: endpointKey,
                state: state,
                definition: definition
            )
            .frame(width: 80, alignment: .trailing)
        }
        .controlSize(.regular)
        .frame(width: 190, alignment: .trailing)
    }

    @ViewBuilder
    private func primaryServerAction(
        for node: ProfileNode,
        endpointKey: String,
        state: IMDSEndpointState,
        definition: IMDSEndpointDefinition
    ) -> some View {
        switch state {
        case .inactive:
            stoppedEndpointAction(
                for: node,
                endpointKey: endpointKey,
                definition: definition,
                readyTitle: "Start",
                readySystemImage: "play.fill"
            )

        case .starting:
            Button {} label: {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Starting")
                }
            }
            .buttonStyle(.bordered)
            .disabled(true)

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
            .pressFeedback()

        case .failed:
            stoppedEndpointAction(
                for: node,
                endpointKey: endpointKey,
                definition: definition,
                readyTitle: "Retry",
                readySystemImage: "arrow.clockwise"
            )
        }
    }

    @ViewBuilder
    private func stoppedEndpointAction(
        for node: ProfileNode,
        endpointKey: String,
        definition: IMDSEndpointDefinition,
        readyTitle: String,
        readySystemImage: String
    ) -> some View {
        switch credentialState(for: node) {
        case .checking:
            Button {} label: {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Checking")
                }
            }
            .buttonStyle(.bordered)
            .disabled(true)

        case .signingIn:
            Button {} label: {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Signing In")
                }
            }
            .buttonStyle(.bordered)
            .disabled(true)

        case .needsSignIn(let sessionName):
            Button {
                signIn(sessionName: sessionName, profileName: node.id)
            } label: {
                Label("Sign In", systemImage: "person.badge.key")
            }
            .buttonStyle(.borderedProminent)
            .pressFeedback()

        case .ready:
            Button {
                Task {
                    await startEndpoint(endpointKey: endpointKey, for: node, definition: definition)
                }
            } label: {
                Label(readyTitle, systemImage: readySystemImage)
            }
            .buttonStyle(.borderedProminent)
            .pressFeedback()

        case .unavailable:
            Button {
                navigateToProfile(node.id)
            } label: {
                Label("Profile", systemImage: "person.crop.circle")
            }
            .buttonStyle(.borderedProminent)
            .pressFeedback()
            .help("Review the profile configuration and credentials")
        }
    }

    @ViewBuilder
    private func secondaryServerAction(
        for node: ProfileNode,
        endpointKey: String,
        state: IMDSEndpointState,
        definition: IMDSEndpointDefinition
    ) -> some View {
        switch state {
        case .inactive:
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)

        case .starting:
            Button(role: .cancel) {
                imdsModel.stopEndpoint(forEndpointID: endpointKey)
            } label: {
                Label("Cancel", systemImage: "xmark")
            }
            .buttonStyle(.bordered)
            .pressFeedback()

        case .active:
            Button(role: .destructive) {
                imdsModel.stopEndpoint(forEndpointID: endpointKey)
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .pressFeedback()

        case .failed:
            Button {
                imdsModel.stopEndpoint(forEndpointID: endpointKey)
            } label: {
                Label("Dismiss", systemImage: "xmark")
            }
            .buttonStyle(.bordered)
            .pressFeedback()
        }
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
            logContext: modelContext
        )
    }

    private func credentialCoordinates(
        for node: ProfileNode
    ) -> (session: String, account: String, role: String)? {
        guard let session = node.profile.ssoSession,
              let account = node.profile.ssoAccountId,
              let role = node.profile.ssoRoleName else {
            return nil
        }
        return (session, account, role)
    }

    private func credentialKey(for node: ProfileNode) -> String? {
        guard let coordinates = credentialCoordinates(for: node) else { return nil }
        return "\(coordinates.session):\(coordinates.account):\(coordinates.role)"
    }

    private func credentialState(for node: ProfileNode) -> EndpointCredentialState {
        guard let coordinates = credentialCoordinates(for: node),
              let key = credentialKey(for: node) else {
            return .unavailable
        }

        if credentialsModel.inFlight[coordinates.session] != nil {
            return .signingIn
        }
        if case .signingIn = credentialsModel.status[coordinates.session] {
            return .signingIn
        }
        if credentialsModel.roleRejected.contains(key) {
            return .unavailable
        }

        guard let status = credentialsModel.profileStatus[key] else {
            return .checking
        }
        switch status {
        case .ready:
            return .ready
        case .notSignedIn(let sessionName), .signInExpired(let sessionName):
            return .needsSignIn(sessionName: sessionName)
        }
    }

    private func credentialPrompt(for node: ProfileNode, state: IMDSEndpointState) -> String? {
        guard !state.isActive else { return nil }

        switch credentialState(for: node) {
        case .checking:
            return "Checking whether this profile can provide credentials."
        case .signingIn:
            return "Complete sign-in to return here and start the endpoint."
        case .needsSignIn(let sessionName):
            return "Sign in to \(sessionName) before starting this endpoint."
        case .unavailable:
            return "Review this profile before starting the endpoint."
        case .ready:
            return nil
        }
    }

    private func signIn(sessionName: String, profileName: String) {
        guard let session = profilesModel.findSession(named: sessionName),
              let startURLString = session.session?.ssoStartUrl,
              let startURL = URL(string: startURLString),
              let region = session.session?.ssoRegion else {
            navigateToProfile(profileName)
            return
        }

        let scopes = session.session?.ssoRegistrationScopes ?? ["sso:account:access"]
        Task {
            await credentialsModel.signIn(
                sessionName: sessionName,
                startUrl: startURL,
                region: region,
                scopes: scopes
            )
        }
    }

    private func navigateToProfile(_ profileName: String) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            searchText = ""
            sourceSelection = .profiles
            detailSelection = .profile(name: profileName)
        }
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

            CopyConfirmationButton(value: value)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.08))
        }
    }

    private func configurationCard(for state: IMDSEndpointState, definition: IMDSEndpointDefinition) -> some View {
        DetailCard("Configuration") {
            Button {
                isPresentingEndpointEditor = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pressFeedback()
            .help("Edit endpoint configuration")
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                configurationRow("Port") {
                Text(String(state.port ?? definition.port))
                        .font(.callout.monospacedDigit())
                }

                configurationRow("Bind address") {
                    Text(definition.bindAddress)
                        .font(.callout.monospaced())
                }

                configurationRow("IMDS version") {
                    Text(definition.allowsIMDSv1 ? "v1 + v2" : "v2 only")
                        .font(.callout.monospaced())
                }

                configurationRow("Hop limit") {
                    Text(String(definition.hopLimit))
                        .font(.callout.monospacedDigit())
                }

                configurationRow("Folder") {
                    MetadataFolderPicker(
                        objectKind: .imdsEndpoint,
                        objectID: definition.stableIDString,
                        isEnabled: true
                    )
                    .labelsHidden()
                    .controlSize(.small)
                }
            }
        }
    }

    private func configurationRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .background(Color.black.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.08))
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

}

private struct IMDSActivityCard: View {
    let state: IMDSEndpointState
    let runtime: IMDSRuntimeInfo?
    let endpointID: String
    @State private var page = 0

    var body: some View {
        IMDSActivityPage(
            state: state,
            liveEvents: runtime?.activity ?? [],
            endpointID: endpointID,
            page: page,
            onPreviousPage: { page = max(0, page - 1) },
            onNextPage: { page += 1 }
        )
    }
}

private struct IMDSActivityPage: View {
    private static let pageSize = 25

    let state: IMDSEndpointState
    let liveEvents: [IMDSRequestLog]
    let page: Int
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void
    @Query private var persistedEntries: [IMDSEndpointLogEntry]

    init(
        state: IMDSEndpointState,
        liveEvents: [IMDSRequestLog],
        endpointID: String,
        page: Int,
        onPreviousPage: @escaping () -> Void,
        onNextPage: @escaping () -> Void
    ) {
        self.state = state
        self.liveEvents = liveEvents
        self.page = page
        self.onPreviousPage = onPreviousPage
        self.onNextPage = onNextPage

        var descriptor = FetchDescriptor<IMDSEndpointLogEntry>(
            predicate: #Predicate { $0.endpointIDString == endpointID },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = Self.pageSize + 1
        descriptor.fetchOffset = page * Self.pageSize
        _persistedEntries = Query(descriptor)
    }

    var body: some View {
        DetailCard("Activity") {
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
                    page > 0 ? "No Requests on This Page" : (state.isActive ? "No Requests Yet" : "No Requests"),
                    systemImage: "list.bullet.rectangle",
                    description: Text(page > 0
                        ? "Return to newer requests."
                        : "Start the endpoint to see IMDS requests here.")
                )
                .frame(maxWidth: .infinity, minHeight: 92)
            }

            if page > 0 || hasNextPage {
                Divider()
                    .padding(.top, 4)

                HStack {
                    Text(pageRangeLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Previous", systemImage: "chevron.left", action: onPreviousPage)
                        .disabled(page == 0)
                    Button("Next", systemImage: "chevron.right", action: onNextPage)
                        .disabled(!hasNextPage)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 10)
            }
        }
    }

    private var hasNextPage: Bool {
        persistedEntries.count > Self.pageSize
    }

    private var pageRangeLabel: String {
        if page == 0 {
            return "Newest \(events.count)"
        }
        let first = page * Self.pageSize + 1
        guard !events.isEmpty else { return "No requests" }
        return "Requests \(first)–\(first + events.count - 1)"
    }

    private var events: [IMDSRequestLog] {
        let persisted = persistedEntries.prefix(Self.pageSize).map(IMDSRequestLog.init(entry:))
        guard page == 0 else { return persisted }

        var seen = Set<UUID>()
        return (liveEvents + persisted)
            .sorted { $0.timestamp > $1.timestamp }
            .filter { seen.insert($0.id).inserted }
            .prefix(Self.pageSize)
            .map { $0 }
    }
}

private struct IMDSStatusBadge: View {
    let title: String
    let color: Color
    var minimumWidth: CGFloat? = nil

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .frame(minWidth: minimumWidth)
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.16), in: Capsule())
    }
}

private extension IMDSRequestLog {
    nonisolated init(entry: IMDSEndpointLogEntry) {
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

#if DEBUG

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
    @State private var detailSelection: DetailSelection?
    @State private var sourceSelection: SourceSelection = .imdsEndpoints
    @State private var searchText = ""
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
        _detailSelection = State(initialValue: .imds(endpointID: endpoint.stableIDString))
        self.metadataContainer = metadataContainer
    }

    var body: some View {
        IMDSDetailView(
            endpointID: Self.endpointID.uuidString,
            detailSelection: $detailSelection,
            sourceSelection: $sourceSelection,
            searchText: $searchText
        )
        .environment(ProfilesModel.previewLoaded(config: PreviewAWSFixtures.mockupConfig))
        .environment(CredentialsModel(service: PreviewIdentityCenterService()))
        .environment(model)
        .modelContainer(metadataContainer)
        .frame(width: 920, height: 720)
    }
}

#endif
