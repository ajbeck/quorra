enum DetailSelection: Hashable, Sendable {
    case session(name: String)
    case profile(name: String)
    case imds(endpointID: String)
    case clientVPN(id: String)
    case databaseConnection(id: String)
    case databaseCredential(id: String)
}
