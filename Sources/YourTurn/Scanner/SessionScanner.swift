import Foundation

/// Scans `~/.claude/projects` and pulls out all recent sessions.
enum SessionScanner {
    static let projectsRoot = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: ".claude/projects", directoryHint: .isDirectory)

    /// Defaults to the last 14 days. Measured distribution: 19 files in the last 1 day,
    /// 209 in 7 days, 280 in 14 days, 488 in 30 days.
    static func scan(within window: TimeInterval = 14 * 86_400, now: Date = Date()) -> [Session] {
        let files = sessionFiles(modifiedSince: now.addingTimeInterval(-window))
        guard !files.isEmpty else { return [] }

        var results = [Session?](repeating: nil, count: files.count)
        results.withUnsafeMutableBufferPointer { buffer in
            let sendable = UncheckedSendable(buffer)
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                sendable.value[i] = makeSession(files[i])
            }
        }
        return results.compactMap { $0 }.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Only reads the `projects/<slug>/<uuid>.jsonl` level.
    ///
    /// Key point: never recurse. One level deeper, `<slug>/<uuid>/subagents/agent-*.jsonl` are
    /// subagent transcripts — measured 293 of them — and recursive scanning would inflate the
    /// session count with bogus data.
    private static func sessionFiles(modifiedSince cutoff: Date) -> [(URL, Date)] {
        let fm = FileManager.default
        guard let slugs = try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(URL, Date)] = []
        for slug in slugs {
            guard (try? slug.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let entries = try? fm.contentsOfDirectory(
                      at: slug, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
                  ) else { continue }

            for entry in entries where entry.pathExtension == "jsonl" {
                guard let mtime = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate, mtime >= cutoff else { continue }
                files.append((entry, mtime))
            }
        }
        return files
    }

    private static func makeSession(_ file: (url: URL, mtime: Date)) -> Session? {
        guard let scan = JSONLTailReader.scan(file.url) else { return nil }
        // cwd drives grouping and every action (resume / open editor); without it the
        // session is meaningless.
        guard let cwd = scan.cwd else { return nil }

        return Session(
            id: scan.sessionId ?? file.url.deletingPathExtension().lastPathComponent,
            fileURL: file.url,
            projectPath: cwd,
            gitBranch: scan.gitBranch,
            title: scan.title,
            summary: scan.summary,
            lastPrompt: scan.lastPrompt,
            // mtime is only a rough filter for "should this file be read at all"; display
            // and sorting always use the record's own timestamp.
            lastActivity: scan.lastTimestamp ?? file.mtime,
            tail: scan.tail
        )
    }
}

/// `concurrentPerform` writes to pre-allocated, non-overlapping indices, so there's no actual
/// data race — but the compiler can't prove that, hence this wrapper to cross the Sendable check.
/// Shared with `UsageScanner`, which fans out the same way.
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
