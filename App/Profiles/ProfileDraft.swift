import Foundation
import QuorraAppLogic

/// The editable fields of a profile, compared against the stored values to drive Save and Discard.
struct ProfileDraft: Equatable {
    var region: String
    var accountID: String
    var roleName: String

    init(_ profile: ProfileDefinition) {
        region = profile.region ?? ""
        accountID = profile.accountID
        roleName = profile.roleName
    }

    var trimmedRegion: String { region.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedAccountID: String { accountID.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedRoleName: String { roleName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var validationMessage: String? {
        guard !trimmedAccountID.isEmpty else { return "Account ID is required." }
        guard !trimmedRoleName.isEmpty else { return "Role name is required." }
        return nil
    }

    func apply(to profile: ProfileDefinition) {
        profile.region = trimmedRegion.isEmpty ? nil : trimmedRegion
        profile.accountID = trimmedAccountID
        profile.roleName = trimmedRoleName
        profile.updatedAt = .now
    }
}
