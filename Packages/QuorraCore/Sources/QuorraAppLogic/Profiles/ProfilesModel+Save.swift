import AWSConfigINI
import Foundation

public extension ProfilesModel {
    func save(_ updated: Profile, for node: ProfileNode, mode: ManagedMode = .managed) async throws {
        let folder = try requireCurrentFolder()
        let flavor = node.writeFlavor
        let url = folder.appending(path: flavor == .config ? "config" : "credentials")
        try AWSConfigINIDocument.update(at: url, flavor: flavor, mode: mode) { (document: inout AWSConfigINIDocument) throws(AWSConfigINIError) in
            try AWSConfigINIEncoder().encodeProfile(updated, named: node.id, into: &document)
        }
        await reload()
    }

    func save(_ updated: SSOSession, for node: SSOSessionNode, mode: ManagedMode = .managed) async throws {
        let folder = try requireCurrentFolder()
        let url = folder.appending(path: "config")
        try AWSConfigINIDocument.update(at: url, flavor: .config, mode: mode) { (document: inout AWSConfigINIDocument) throws(AWSConfigINIError) in
            try AWSConfigINIEncoder().encode(updated, into: &document, section: "sso-session \(node.id)")
        }
        await reload()
    }

    func createProfile(named rawName: String, profile: Profile, mode: ManagedMode) async throws {
        let name = try normalizedNewName(rawName, kind: "Profile")
        guard findProfile(named: name) == nil else {
            throw AWSConfigINIError.malformedInput("Profile '\(name)' already exists.")
        }
        let folder = try requireCurrentFolder()
        try AWSConfigINIDocument.update(at: folder.appending(path: "config"), flavor: .config, mode: mode) { (document: inout AWSConfigINIDocument) throws(AWSConfigINIError) in
            if document.profileSection(named: name) != nil {
                throw AWSConfigINIError.malformedInput("Profile '\(name)' already exists.")
            }
            try AWSConfigINIEncoder().encodeProfile(profile, named: name, into: &document)
        }
        await reload()
    }

    func createSession(named rawName: String, session: SSOSession, mode: ManagedMode) async throws {
        let name = try normalizedNewName(rawName, kind: "SSO session")
        guard findSession(named: name) == nil else {
            throw AWSConfigINIError.malformedInput("SSO session '\(name)' already exists.")
        }
        let folder = try requireCurrentFolder()
        try AWSConfigINIDocument.update(at: folder.appending(path: "config"), flavor: .config, mode: mode) { (document: inout AWSConfigINIDocument) throws(AWSConfigINIError) in
            let sectionName = "sso-session \(name)"
            if document.section(sectionName) != nil {
                throw AWSConfigINIError.malformedInput("SSO session '\(name)' already exists.")
            }
            try AWSConfigINIEncoder().encode(session, into: &document, section: sectionName)
        }
        await reload()
    }

    func deleteProfile(named name: String, mode: ManagedMode) async throws {
        let folder = try requireCurrentFolder()
        try AWSConfigINIDocument.update(at: folder.appending(path: "config"), flavor: .config, mode: mode) { (document: inout AWSConfigINIDocument) throws(AWSConfigINIError) in
            document.deleteSection(document.flavor.profileSectionName(for: name))
        }
        try AWSConfigINIDocument.update(at: folder.appending(path: "credentials"), flavor: .credentials, mode: mode) { (document: inout AWSConfigINIDocument) throws(AWSConfigINIError) in
            document.deleteSection(document.flavor.profileSectionName(for: name))
        }
        await reload()
    }

    func deleteSession(named name: String, mode: ManagedMode) async throws {
        let folder = try requireCurrentFolder()
        try AWSConfigINIDocument.update(at: folder.appending(path: "config"), flavor: .config, mode: mode) { (document: inout AWSConfigINIDocument) throws(AWSConfigINIError) in
            document.deleteSection("sso-session \(name)")
        }
        await reload()
    }

    private func requireCurrentFolder() throws(AWSConfigINIError) -> URL {
        guard let folder = currentFolder else {
            throw AWSConfigINIError.ioError(
                URL(filePath: "/dev/null"),
                underlying: NSError(domain: "Quorra", code: -1)
            )
        }
        return folder
    }

    private func normalizedNewName(_ rawName: String, kind: String) throws(AWSConfigINIError) -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw AWSConfigINIError.malformedInput("\(kind) name is required.")
        }
        guard !name.contains("\n"), !name.contains("\r") else {
            throw AWSConfigINIError.malformedInput("\(kind) name must be a single line.")
        }
        return name
    }
}
