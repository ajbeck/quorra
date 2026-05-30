/// The credential source of a profile, as shown by the row's `via` badge.
/// `.session` is colored (per SSO org); `.longTerm` / `.other` render neutral.
nonisolated enum ProfileVia: Hashable {
    case session(String)
    case longTerm
    case other

    /// The text shown in the badge.
    var label: String {
        switch self {
        case .session(let name): return name
        case .longTerm: return "long-term"
        case .other: return "other"
        }
    }

    /// Only SSO sessions carry a per-session hue; everything else is neutral.
    var isSSO: Bool {
        if case .session = self { return true }
        return false
    }
}

/// A profile flattened out of `SidebarGroups` for the single-column Profiles list,
/// tagged with the `via` descriptor its row needs. Account/role are intentionally
/// not carried here — they live in the detail pane, not the sidebar row.
struct SidebarProfileItem: Identifiable, Hashable {
    let node: ProfileNode
    let via: ProfileVia
    var id: String { node.id }
}

extension SidebarGroups {
    /// All profiles as one flat, ordered list for the Profiles tab.
    ///
    /// Order: `default` first, then alphabetical by name (matching the buckets'
    /// `profileSortOrder`). Each profile is tagged from the bucket it came out of —
    /// SSO-session profiles take the session's name as a colored `via`, long-term and
    /// other profiles render neutral.
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
