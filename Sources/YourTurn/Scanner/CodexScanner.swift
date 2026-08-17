import Foundation
import SQLite3

/// Scans `~/.codex` and pulls out recent Codex threads.
///
/// The shape of the problem is the mirror image of `SessionScanner`'s. Claude Code keeps no
/// index at all, so everything — title, cwd, branch, your last prompt — has to be dug out of
/// the transcript tail. Codex keeps a SQLite index that already holds every one of those as a
/// column, and measured on this machine it is *more* complete than the tail-reading it
/// replaces: 458 of 459 threads carry a title and a first user message, against Claude's
/// measured 93% and 99% from parsing.
///
/// So the split is: **the database answers "what is this session", the rollout tail answers
/// "what is it doing right now"** — which is the one thing the database does not track.
///
/// Uses the system SQLite3 (`import SQLite3`), so this adds no package. The database is opened
/// read-only through a `file:` URI; Codex holds it in WAL mode while running and readers are
/// not blocked by that.
enum CodexScanner {
    static let root = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: ".codex", directoryHint: .isDirectory)

    /// Same 14-day window as the Claude scanner, so the two lists age out together.
    static func scan(within window: TimeInterval = 14 * 86_400, now: Date = Date()) -> [Session] {
        guard let db = StateDB.open() else { return [] }
        defer { db.close() }

        let cutoff = now.addingTimeInterval(-window)
        let rows = db.threads(updatedSince: cutoff)
        guard !rows.isEmpty else { return [] }

        var results = [Session?](repeating: nil, count: rows.count)
        results.withUnsafeMutableBufferPointer { buffer in
            let sendable = UncheckedSendable(buffer)
            DispatchQueue.concurrentPerform(iterations: rows.count) { i in
                sendable.value[i] = makeSession(rows[i])
            }
        }
        return results.compactMap { $0 }.sorted { $0.lastActivity > $1.lastActivity }
    }

    private static func makeSession(_ row: ThreadRow) -> Session? {
        // cwd drives grouping and every action, same rule as the Claude scanner.
        guard !row.cwd.isEmpty else { return nil }
        let tail = row.rolloutPath.map(RolloutTailReader.scan) ?? nil

        return Session(
            id: row.id,
            agent: .codex,
            fileURL: URL(fileURLWithPath: row.rolloutPath ?? ""),
            projectPath: row.cwd,
            gitBranch: row.gitBranch,
            title: row.title,
            // Codex has no away_summary — nothing is written for the express purpose of
            // telling you what to do next. `task_complete.last_agent_message` is the closest
            // thing that exists (measured 93% coverage, against Claude's 72% for a summary
            // that was actually written for this), and it's the agent's own sign-off, so it
            // reads as the same kind of sentence.
            summary: tail?.lastAgentMessage,
            lastPrompt: tail?.lastUserMessage ?? row.firstUserMessage,
            lastActivity: row.updatedAt,
            tail: tail?.marker ?? .unknown
        )
    }
}

/// One row of `threads`, narrowed to the columns the app uses.
struct ThreadRow: Sendable {
    let id: String
    let rolloutPath: String?
    let cwd: String
    let title: String?
    let firstUserMessage: String?
    let gitBranch: String?
    let updatedAt: Date
}

/// Read-only access to `~/.codex/state_<n>.sqlite`.
///
/// **Every failure here is "there are no Codex sessions", never a crash.** The trailing number
/// is a schema-migration counter — this machine is on `state_5`, alongside `logs_2`,
/// `goals_1`, `memories_1` and `queue_1`, so the format has already been rewritten five times
/// and will be again. The file is found by globbing rather than by a hardcoded name, the
/// query names only the seven columns actually needed, and a `prepare` failure (a renamed or
/// dropped column) returns an empty list. Someone with no Codex installed, an older Codex, or
/// a newer one hits the same quiet path.
private struct StateDB {
    let handle: OpaquePointer

    static func open() -> StateDB? {
        guard let path = newestStateFile() else { return nil }
        var handle: OpaquePointer?
        // SQLITE_OPEN_URI is what makes the `file:` prefix meaningful; without it the whole
        // string is taken as a literal filename.
        let ok = sqlite3_open_v2(
            "file:\(path)?mode=ro", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil
        ) == SQLITE_OK
        guard ok, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        return StateDB(handle: handle)
    }

    func close() { sqlite3_close(handle) }

    /// Picks the highest-numbered `state_<n>.sqlite`. A Codex upgrade writes a new file rather
    /// than migrating in place, and the old one is left behind holding stale threads.
    private static func newestStateFile() -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: CodexScanner.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }

        return entries
            .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
            .max { a, b in
                version(a.lastPathComponent) < version(b.lastPathComponent)
            }?
            .path
    }

    private static func version(_ name: String) -> Int {
        Int(name.dropFirst("state_".count).prefix(while: \.isNumber)) ?? 0
    }

    func threads(updatedSince cutoff: Date) -> [ThreadRow] {
        // `source NOT LIKE '{%'` is the subagent filter, and it's the exact analogue of the
        // Claude scanner's "never recurse into subagents/". Measured: real sessions carry a
        // plain word ('vscode' 333, 'cli' 10, 'exec' 4), while a subagent's source is a JSON
        // blob — {"subagent":{"other":"guardian"}} and friends, 104 of them. Matching on the
        // brace rejects every shape of those without an allowlist that a new Codex could
        // outgrow.
        let sql = """
        SELECT id, rollout_path, cwd, title, first_user_message, git_branch, updated_at_ms
        FROM threads
        WHERE archived = 0 AND source NOT LIKE '{%' AND updated_at_ms >= ?
        ORDER BY updated_at_ms DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(cutoff.timeIntervalSince1970 * 1000))

        var rows: [ThreadRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ i: Int32) -> String? {
                sqlite3_column_text(stmt, i).map { String(cString: $0) }
            }
            guard let id = text(0), let cwd = text(2) else { continue }
            rows.append(ThreadRow(
                id: id,
                rolloutPath: text(1),
                cwd: cwd,
                title: text(3),
                firstUserMessage: text(4),
                gitBranch: text(5),
                updatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 6)) / 1000)
            ))
        }
        return rows
    }
}
