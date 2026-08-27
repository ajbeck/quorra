/// The credential source of a profile, as shown by the row's `via` badge.
/// `.session` is colored (per SSO org); `.longTerm` / `.other` render neutral.
public nonisolated enum ProfileVia: Hashable {
    case session(String)
    case longTerm
    case other

    /// The text shown in the badge.
    public var label: String {
        switch self {
        case .session(let name): return name
        case .longTerm: return "long-term"
        case .other: return "other"
        }
    }

    /// Only SSO sessions carry a per-session hue; everything else is neutral.
    public var isSSO: Bool {
        if case .session = self { return true }
        return false
    }
}

/// A profile flattened out of `SidebarGroups` for the single-column Profiles list,
/// tagged with the `via` descriptor its row needs. Account/role are intentionally
/// not carried here — they live in the detail pane, not the sidebar row.
public struct SidebarProfileItem: Identifiable, Hashable {
    public let node: ProfileNode
    public let via: ProfileVia
    public var id: String { node.id }

    public init(node: ProfileNode, via: ProfileVia) {
        self.node = node
        self.via = via
    }
}

public extension SidebarGroups {
    /// All profiles as one flat, ordered list for the Profiles tab.
    ///
    /// Order: `default` first, then alphabetical by name. Each profile is tagged
    /// with the bucket it came from so the row can display its credential source.
    var flatProfiles: [SidebarProfileItem] {
        var items: [SidebarProfileItem] = []
        for session in ssoSessions {
            for node in session.profiles {
                items.append(SidebarProfileItem(node: node, via: .session(session.id)))
            }
        }
        items += longTermKeys.map { SidebarProfileItem(node: $0, via: .longTerm) }
        items += other.map { SidebarProfileItem(node: $0, via: .other) }

        return items.sorted { a, b in
            let aDefault = a.node.id == "default"
            let bDefault = b.node.id == "default"
            if aDefault != bDefault { return aDefault }
            return a.node.id < b.node.id
        }
    }
}
