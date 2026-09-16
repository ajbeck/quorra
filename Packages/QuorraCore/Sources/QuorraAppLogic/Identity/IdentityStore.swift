import Foundation
import SwiftData

/// Store lookups shared by the runtime, the IPC handlers, and the views.
@MainActor
public enum IdentityStore {
    public static func sessions(in context: ModelContext) throws -> [SessionDefinition] {
        try context.fetch(FetchDescriptor<SessionDefinition>())
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func session(named name: String, in context: ModelContext) throws -> SessionDefinition? {
        var descriptor = FetchDescriptor<SessionDefinition>(predicate: #Predicate { $0.name == name })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Every profile, linked to a session or not, sorted by name.
    public static func profiles(in context: ModelContext) throws -> [ProfileDefinition] {
        try context.fetch(FetchDescriptor<ProfileDefinition>())
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Profiles that can serve credentials: those linked to a session, sorted by name.
    public static func eligibleProfiles(in context: ModelContext) throws -> [ProfileDefinition] {
        try context.fetch(FetchDescriptor<ProfileDefinition>())
            .filter { $0.session != nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func profile(named name: String, in context: ModelContext) throws -> ProfileDefinition? {
        var descriptor = FetchDescriptor<ProfileDefinition>(predicate: #Predicate { $0.name == name })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
