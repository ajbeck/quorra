import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    @Environment(ProfilesModel.self) private var profilesModel

    var body: some View {
        List(selection: $selection) {
            Section("SSO Sessions") {
                Text("(stub — phase 7)")
                    .foregroundStyle(.tertiary)
            }
        }
        .listStyle(.sidebar)
    }
}

#Preview {
    SidebarView(selection: .constant(nil))
        .environment(ProfilesModel())
}
