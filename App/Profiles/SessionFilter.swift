enum SessionFilter: Hashable, Sendable {
    case all
    case session(name: String)

    var sessionName: String? {
        if case .session(let name) = self { return name }
        return nil
    }
}
