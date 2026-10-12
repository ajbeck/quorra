import AppKit
import QuorraAppLogic
import SwiftUI

/// One IMDS endpoint in the menu bar: its state in the title, its actions in a submenu.
/// A menu cannot show an error, so a failed action opens the endpoint in the main window,
/// where the failure is displayed.
struct EndpointMenu: View {
    let definition: IMDSEndpointDefinition
    let state: IMDSEndpointState
    let profileChoices: [String]
    let runtimeCoordinator: AppRuntimeCoordinator
    let showInQuorra: (DetailSelection) -> Void

    var body: some View {
        Menu {
            Text(statusLine)

            if state.isActive || state.isStarting {
                Button("Stop") {
                    Task { await runtimeCoordinator.stopEndpoint(definition) }
                }
            } else {
                Button("Start") {
                    Task {
                        do {
                            try await runtimeCoordinator.startEndpoint(definition)
                        } catch {
                            showInQuorra(selection)
                        }
                    }
                }
                .disabled(definition.profileName.isEmpty)
            }

            Picker("Serve Profile", selection: servedProfile) {
                ForEach(profileChoices, id: \.self) { name in
                    Text(name).tag(name)
                }
            }

            Divider()

            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }

            Button("Show in Quorra…") {
                showInQuorra(selection)
            }
        } label: {
            Label(menuTitle(title), systemImage: statusImage)
                .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel("\(title), \(statusLine)")
    }

    private var isDefault: Bool {
        DefaultIMDSEndpoint.matches(definition)
    }

    private var selection: DetailSelection {
        .imds(endpointID: definition.stableIDString)
    }

    private var port: Int {
        isDefault ? definition.port : state.port ?? definition.port
    }

    private var url: String {
        "http://\(definition.bindAddress):\(port)"
    }

    private var title: String {
        if isDefault {
            return "IMDS · \(definition.profileName.isEmpty ? "No Profile" : definition.profileName)"
        }
        return "\(definition.name) · :\(port)"
    }

    private var statusLine: String {
        switch state {
        case .inactive:
            return "Off"
        case .starting:
            return "Starting…"
        case .active:
            return "Running"
        case .failed:
            return "Needs attention"
        }
    }

    private var statusImage: String {
        switch state {
        case .inactive:
            return "circle"
        case .starting:
            return "circle.dotted"
        case .active:
            return "circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var servedProfile: Binding<String> {
        Binding(
            get: { definition.profileName },
            set: { newValue in
                guard newValue != definition.profileName else { return }
                Task {
                    do {
                        try await runtimeCoordinator.switchEndpointProfile(definition, to: newValue)
                    } catch {
                        showInQuorra(selection)
                    }
                }
            }
        )
    }
}
