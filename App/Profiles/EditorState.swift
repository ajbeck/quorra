import Observation

@Observable
@MainActor
final class EditorState {
    var dirtyDescription: String?
}
