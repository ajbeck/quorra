import AWSConfigINI

/// Parsed AWS profile data shared by graphical and command-line interfaces.
public struct ProfileCatalog: Sendable {
    public let configDocument: AWSConfigINIDocument
    public let credentialsDocument: AWSConfigINIDocument
    public let groups: SidebarGroups

    public init(
        configDocument: AWSConfigINIDocument,
        credentialsDocument: AWSConfigINIDocument,
        groups: SidebarGroups
    ) {
        self.configDocument = configDocument
        self.credentialsDocument = credentialsDocument
        self.groups = groups
    }
}
