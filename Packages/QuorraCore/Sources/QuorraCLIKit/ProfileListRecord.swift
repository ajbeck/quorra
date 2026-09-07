import QuorraProfiles

struct ProfileListRecord: Encodable, Equatable {
    let name: String
    let source: String
    let session: String?
    let region: String?
    let account: String?
    let role: String?

    init(item: SidebarProfileItem) {
        name = item.id
        source = item.via.label
        session = item.node.profile.ssoSession
        region = item.node.profile.region ?? item.node.profile.ssoRegion
        account = item.node.profile.ssoAccountId
        role = item.node.profile.ssoRoleName
    }
}
