import QuorraProfiles

// Preserve QuorraAppLogic's existing public profile API while the lightweight
// profile catalog lives in its own module for command-line consumers.
public typealias ProfileCatalog = QuorraProfiles.ProfileCatalog
public typealias ProfileCatalogLoader = QuorraProfiles.ProfileCatalogLoader
public typealias ProfileNode = QuorraProfiles.ProfileNode
public typealias ProfileVia = QuorraProfiles.ProfileVia
public typealias SidebarGroups = QuorraProfiles.SidebarGroups
public typealias SidebarProfileItem = QuorraProfiles.SidebarProfileItem
public typealias SSOSessionNode = QuorraProfiles.SSOSessionNode
