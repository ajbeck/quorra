import Foundation
import AWSConfigINI

extension ProfilesModel {
    func save(_ updated: Profile, for node: ProfileNode, mode: ManagedMode = .managed) async throws {
        let folder = try requireCurrentFolder()
        let flavor = node.writeFlavor
        let url = folder.appending(path: flavor == .config ? "config" : "credentials")
        try AWSConfigINIDocument.update(at: url, flavor: flavor, mode: mode) { (doc: inout AWSConfigINIDocument) throws(AWSConfigINIError) in
            try AWSConfigINIEncoder().encodeProfile(updated, named: node.id, into: &doc)
        }
        await reload()
    }

    func save(_ updated: SSOSession, for node: SSOSessionNode, mode: ManagedMode = .managed) async throws {
        let folder = try requireCurrentFolder()
        let url = folder.appending(path: "config")
        try AWSConfigINIDocument.update(at: url, flavor: .config, mode: mode) { (doc: inout AWSConfigINIDocument) throws(AWSConfigINIError) in
            try AWSConfigINIEncoder().encode(updated, into: &doc, section: "sso-session \(node.id)")
        }
        await reload()
    }

    func createProfile(named rawName: String, profile: Profile, mode: ManagedMode) async throws {
        let name = try normalizedNewName(rawName, kind: "Profile")
        guard findProfile(named: name) == nil else {
            throw AWSConfigINIError.malformedInput("Profile '\(name)' already exists.")
        }

        let folder = try requireCurrentFolder()
        let url = folder.appending(path: "config")
        try AWSConfigINIDocument.update(at: url, flavor: .config, mode: mode) { (doc: inout AWSConfigINIDocument) throws(AWSConfigINIError) in
            if doc.profileSection(named: name) != nil {
                throw AWSConfigINIError.malformedInput("Profile '\(name)' already exists.")
            }
            try AWSConfigINIEncoder().encodeProfile(profile, named: name, into: &doc)
        }
        await reload()
    }

    func createSession(named rawName: String, session: SSOSession, mode: ManagedMode) async throws {
        let name = try normalizedNewName(rawName, kind: "SSO session")
        guard findSession(named: name) == nil else {
            throw AWSConfigINIError.malformedInput("SSO session '\(name)' already exists.")
        }

        let folder = try requireCurrentFolder()
        let url = folder.appending(path: "config")
        try AWSConfigINIDocument.update(at: url, flavor: .config, mode: mode) { (doc: inout AWSConfigINIDocument) throws(AWSConfigINIError) in
            let sectionName = "sso-session \(name)"
            if doc.section(sectionName) != nil {
                throw AWSConfigINIError.malformedInput("SSO session '\(name)' already exists.")
            }
            try AWSConfigINIEncoder().encode(session, into: &doc, section: sectionName)
        }
        await reload()
    }

    func deleteProfile(named name: String, mode: ManagedMode) async throws {
        let folder = try requireCurrentFolder()

        let configURL = folder.appending(path: "config")
        try AWSConfigINIDocument.update(at: configURL, flavor: .config, mode: mode) { (doc: inout AWSConfigINIDocument) throws(AWSConfigINIError) in
            doc.deleteSection(doc.flavor.profileSectionName(for: name))
        }

        let credentialsURL = folder.appending(path: "credentials")
        try AWSConfigINIDocument.update(at: credentialsURL, flavor: .credentials, mode: mode) { (doc: inout AWSConfigINIDocument) throws(AWSConfigINIError) in
            doc.deleteSection(doc.flavor.profileSectionName(for: name))
        }

        await reload()
    }

    func deleteSession(named name: String, mode: ManagedMode) async throws {
        let folder = try requireCurrentFolder()
        let url = folder.appending(path: "config")
        try AWSConfigINIDocument.update(at: url, flavor: .config, mode: mode) { (doc: inout AWSConfigINIDocument) throws(AWSConfigINIError) in
            doc.deleteSection("sso-session \(name)")
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
