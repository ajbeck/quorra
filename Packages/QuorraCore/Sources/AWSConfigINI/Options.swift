// AWSConfigINIDocument.Options — parse and write options.
//
// Decision D17: preserveBOM defaults to true.

/// Options that control parse and write behavior.
public struct AWSConfigINIDocumentOptions: Sendable {
    /// When `true` (default), a BOM present in the input is re-emitted on write.
    /// Decision D17.
    public var preserveBOM: Bool

    /// Text for the managed-mode header comment prepended on first managed write.
    /// Decision D04; used in M08.
    public var managedHeaderText: String

    /// Default options.
    public static let `default` = AWSConfigINIDocumentOptions(
        preserveBOM: true,
        managedHeaderText: "# Managed by Quorra. It updates the sso-session and profile sections it lists and keeps other sections and keys. Formatting is normalized on write."
    )

    public init(preserveBOM: Bool = true, managedHeaderText: String = "# Managed by Quorra. It updates the sso-session and profile sections it lists and keeps other sections and keys. Formatting is normalized on write.") {
        self.preserveBOM = preserveBOM
        self.managedHeaderText = managedHeaderText
    }
}
