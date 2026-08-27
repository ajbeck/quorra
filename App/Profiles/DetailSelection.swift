enum DetailSelection: Hashable, Sendable {
    case session(name: String)
    case profile(name: String)
    case imds(endpointID: String)
}
