import SwiftData
import SwiftUI
import QuorraAppLogic

struct MetadataFolderPicker: View {
    let objectKind: MetadataObjectKind
    let objectID: String
    let isEnabled: Bool

    @Environment(\.modelContext) private var modelContext
    @Query private var folders: [MetadataFolder]
    @Query private var assignments: [MetadataFolderAssignment]
    @State private var saveError: String?

    var body: some View {
        Picker("Folder", selection: selectedFolderID) {
            Text("No Folder")
                .tag(String?.none)

            ForEach(compatibleFolders, id: \.stableIDString) { folder in
                Text(folder.name)
                    .tag(Optional(folder.stableIDString))
            }
        }
        .pickerStyle(.menu)
        .disabled(!isEnabled)
        .alert(
            "Couldn't update folder",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private var compatibleFolders: [MetadataFolder] {
        folders
            .filter { $0.kind == objectKind }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var matchingAssignments: [MetadataFolderAssignment] {
        assignments.filter {
            $0.objectKind == objectKind && $0.objectID == objectID
        }
    }

    private var selectedFolderID: Binding<String?> {
        Binding(
            get: { matchingAssignments.first?.folderIDString },
            set: updateAssignment
        )
    }

    private func updateAssignment(folderIDString: String?) {
        guard folderIDString != matchingAssignments.first?.folderIDString || matchingAssignments.count > 1 else {
            return
        }

        do {
            guard let folderIDString,
                  let folder = compatibleFolders.first(where: { $0.stableIDString == folderIDString }) else {
                for assignment in matchingAssignments {
                    modelContext.delete(assignment)
                }
                try modelContext.save()
                return
            }

            if let assignment = matchingAssignments.first {
                assignment.move(to: folder.stableID)
                for duplicate in matchingAssignments.dropFirst() {
                    modelContext.delete(duplicate)
                }
            } else {
                modelContext.insert(MetadataFolderAssignment(
                    objectKind: objectKind,
                    objectID: objectID,
                    folderID: folder.stableID
                ))
            }
            try modelContext.save()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

#Preview("No Folder") {
    Form {
        MetadataFolderPicker(
            objectKind: .profile,
            objectID: "ac:cp:org_admin",
            isEnabled: true
        )
    }
    .formStyle(.grouped)
    .frame(width: 360, height: 160)
    .modelContainer(try! QuorraMetadataSchema.makeContainer(inMemory: true))
}
