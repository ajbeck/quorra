import Foundation
import AWSConfigINI

extension ProfilesModel {
    func save(_ updated: Profile, for node: ProfileNode) async throws {
        guard let folder = currentFolder else {
            throw AWSConfigINIError.ioError(
                URL(filePath: "/dev/null"),
                underlying: NSError(domain: "Quorra", code: -1)
            )
        }
        let flavor = node.writeFlavor
        let url = folder.appending(path: flavor == .config ? "config" : "credentials")
        try AWSConfigINIDocument.update(at: url, flavor: flavor, mode: .managed) { (doc: inout AWSConfigINIDocument) throws(AWSConfigINIError) in
            try AWSConfigINIEncoder().encodeProfile(updated, named: node.id, into: &doc)
        }
        await reload()
    }

    func save(_ updated: SSOSession, for node: SSOSessionNode) async throws {
        guard let folder = currentFolder else {
            throw AWSConfigINIError.ioError(
                URL(filePath: "/dev/null"),
                underlying: NSError(domain: "Quorra", code: -1)
            )
        }
        let url = folder.appending(path: "config")
        try AWSConfigINIDocument.update(at: url, flavor: .config, mode: .managed) { (doc: inout AWSConfigINIDocument) throws(AWSConfigINIError) in
            try AWSConfigINIEncoder().encode(updated, into: &doc, section: "sso-session \(node.id)")
        }
        await reload()
    }
}
