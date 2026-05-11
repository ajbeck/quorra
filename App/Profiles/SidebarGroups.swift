struct SidebarGroups: Hashable {
    var ssoSessions: [SSOSessionNode]
    var longTermKeys: [ProfileNode]
    var other: [ProfileNode]

    static let empty = SidebarGroups(ssoSessions: [], longTermKeys: [], other: [])
}
