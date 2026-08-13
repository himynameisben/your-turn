import Foundation

/// Remembers what each transcript file contributed, so a rescan only re-reads what changed.
///
/// Keyed on `(size, modified)`. When either moves, the file is parsed **from the top** rather
/// than resumed from a stored byte offset: Claude Code rewrites the metadata records at the
/// tail of a file it hasn't otherwise touched (measured elsewhere in this app at 71% of files,
/// median 3.6h of drift), so an offset can point into rewritten bytes and double-count real
/// money. A full re-read of one changed file costs 150ms at the measured worst case (46MB) and
/// only happens for the handful of sessions actually in use — cheap insurance.
///
/// `@unchecked Sendable`: reads run concurrently from `concurrentPerform`, writes happen after
/// that fan-out completes, and the lock covers both regardless.
final class UsageCache: @unchecked Sendable {
    private struct Entry: Codable {
        let size: Int
        let modified: Date
        let usage: FileUsage
    }

    private var entries: [String: Entry] = [:]
    private var dirty = false
    private let lock = NSLock()
    private let fileURL: URL

    /// Alongside `archived.json` in this app's own Application Support directory —
    /// `~/.claude` is never written to.
    static let defaultURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "YourTurn/usage-cache.plist")
    }()

    init(fileURL: URL = UsageCache.defaultURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? PropertyListDecoder().decode([String: Entry].self, from: data) {
            entries = stored
        }
    }

    func value(for url: URL, stamp: UsageScanner.Stamp) -> FileUsage? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[url.path],
              entry.size == stamp.size, entry.modified == stamp.modified
        else { return nil }
        return entry.usage
    }

    func store(_ usage: FileUsage, for url: URL, stamp: UsageScanner.Stamp) {
        lock.lock()
        defer { lock.unlock() }
        entries[url.path] = Entry(size: stamp.size, modified: stamp.modified, usage: usage)
        dirty = true
    }

    /// Drops entries for files that no longer exist, so a cache that has outlived a year of
    /// deleted transcripts doesn't keep paying to load them.
    func retain(_ paths: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        let stale = entries.keys.filter { !paths.contains($0) }
        guard !stale.isEmpty else { return }
        for path in stale { entries.removeValue(forKey: path) }
        dirty = true
    }

    /// Binary property list rather than JSON: the same 36,000 records encode smaller and
    /// decode several times faster, and the warm path only pays off if loading the cache
    /// costs far less than the 4s scan it replaces.
    func save() {
        lock.lock()
        let snapshot = entries
        let needsWrite = dirty
        dirty = false
        lock.unlock()

        guard needsWrite else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
