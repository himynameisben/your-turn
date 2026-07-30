import Foundation
import Observation

/// Starred projects always sort to the top.
///
/// Stores the project path rather than its name — different directories can have
/// same-named projects (e.g. multiple `backend`s). The type and UserDefaults key keep the
/// old "pin" naming; changing them would wipe out everyone's already-saved preferences.
@Observable
@MainActor
final class PinStore {
    private(set) var pinned: Set<String> = []

    private let key = "pinnedProjects"

    init() {
        pinned = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    func isPinned(_ path: String) -> Bool { pinned.contains(path) }

    func toggle(_ path: String) {
        if pinned.contains(path) { pinned.remove(path) } else { pinned.insert(path) }
        save()
    }

    func clear() {
        pinned.removeAll()
        save()
    }

    private func save() {
        UserDefaults.standard.set(Array(pinned).sorted(), forKey: key)
    }
}
