import Foundation

/// Remembers which sessions have been manually marked as done.
///
/// Deliberately written to this app's own Application Support directory —
/// **never written back to `~/.claude`**, since that's Claude Code's own data and this
/// app only reads it, never writes to it.
@Observable
@MainActor
final class ArchiveStore {
    private(set) var archived: Set<String> = []

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "YourTurn/archived.json")
    }()

    init() { load() }

    func isArchived(_ id: String) -> Bool { archived.contains(id) }

    func toggle(_ id: String) {
        if archived.contains(id) { archived.remove(id) } else { archived.insert(id) }
        save()
    }

    func clear() {
        archived.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return }
        archived = Set(ids)
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(Array(archived).sorted()) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
