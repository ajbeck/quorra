import ArgumentParser

enum ProfileListOutputFormat: String, CaseIterable, ExpressibleByArgument {
    case table
    case names
    case json
}
