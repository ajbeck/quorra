public struct SidebarGroups: Hashable {
    public var ssoSessions: [SSOSessionNode]
    public var longTermKeys: [ProfileNode]
    public var other: [ProfileNode]

    public init(ssoSessions: [SSOSessionNode], longTermKeys: [ProfileNode], other: [ProfileNode]) {
        self.ssoSessions = ssoSessions
        self.longTermKeys = longTermKeys
        self.other = other
    }

    public static var empty: SidebarGroups {
        SidebarGroups(ssoSessions: [], longTermKeys: [], other: [])
    }
}
