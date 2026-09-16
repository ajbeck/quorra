import Foundation
import QuorraAppLogic

/// The editable fields of a session, compared against the stored values to drive Save and Discard.
struct SessionDraft: Equatable {
    var startURL: String
    var region: String
    var registrationScopes: [String]

    init(startURL: String = "", region: String = "", registrationScopes: [String] = ["sso:account:access"]) {
        self.startURL = startURL
        self.region = region
        self.registrationScopes = registrationScopes
    }

    init(_ session: SessionDefinition) {
        self.init(startURL: session.startURL, region: session.region, registrationScopes: session.registrationScopes)
    }

    var trimmedStartURL: String { startURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedRegion: String { region.trimmingCharacters(in: .whitespacesAndNewlines) }
    var resolvedScopes: [String] { registrationScopes.isEmpty ? ["sso:account:access"] : registrationScopes }

    /// The first problem that would stop these values from signing in, or `nil` when they are usable.
    var validationMessage: String? {
        guard let url = URL(string: trimmedStartURL), url.scheme?.lowercased() == "https", url.host() != nil else {
            return "Start URL must be an https URL, such as https://my-domain.awsapps.com/start."
        }
        guard !trimmedRegion.isEmpty else {
            return "Region is required. Use the region of your IAM Identity Center instance, such as us-east-1."
        }
        return nil
    }

    func apply(to session: SessionDefinition) {
        session.startURL = trimmedStartURL
        session.region = trimmedRegion
        session.registrationScopes = resolvedScopes
        session.updatedAt = .now
    }
}
