import Foundation

struct ResolvedSession: Identifiable, Sendable {
    let session: Session
    let state: SessionState
    /// The live process this session matched to; nil means the session's terminal has closed.
    let process: AgentProcess?
    /// The status the agent reported about itself (from `~/.claude/sessions/<pid>.json`).
    /// nil means this session isn't registered — or is a Codex thread, which never reports one
    /// — and the state is inferred from the tail record and the process instead.
    let live: LiveStatus?
    /// Whether the process was bound to this session exactly — a registry entry for Claude, a
    /// held writer lock for Codex — rather than by the top-N guess. Tracked separately from
    /// `live` because Codex is always exact and yet never reports a status, so a `--dump` that
    /// keyed "exact" off `live` would report every Codex row as a guess.
    let exactMatch: Bool
    var id: String { session.id }

    var isLive: Bool { process != nil }

    /// What it's stuck on a dialog waiting for you to answer. Only set when the registry
    /// reports `waiting`.
    var waitingFor: String? {
        if case .waiting(let reason) = live { return reason ?? L("your response") }
        return nil
    }

    /// The "AI" line in the list — the next step Claude leaves you when it stops.
    ///
    /// Blank when there's no summary — **don't fall back to last-prompt**: that sentence is
    /// already on the "You" line, and printing the same sentence twice just makes it look broken.
    /// Also hidden while running: the summary is a snapshot from the last time you stepped
    /// away, and Claude is now doing something else.
    var actionLine: String? {
        guard state != .running else { return nil }
        switch session.nextAction {
        case .pending(let text): return text
        case .clear: return state == .awaiting ? L("Nothing pending — over to you.") : nil
        case .unknown(let fallback): return fallback
        }
    }
}

struct ProjectGroup: Identifiable, Sendable {
    let path: String
    let sessions: [ResolvedSession]
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var lastActivity: Date { sessions.first?.session.lastActivity ?? .distantPast }

    /// Sessions whose terminal is still open — only these show up in grid cards and the menu bar.
    var active: [ResolvedSession] { sessions.filter { $0.state.isActive } }
    /// Sessions whose terminal has closed, treated as done. Only appears in the resume list.
    var history: [ResolvedSession] { sessions.filter { !$0.state.isActive } }

    var awaitingCount: Int { sessions.count { $0.state == .awaiting } }
    var runningCount: Int { sessions.count { $0.state == .running } }
    var hasActive: Bool { !active.isEmpty }
}

/// Merges "scanned sessions" with "live processes" into the final state.
///
/// Two-phase matching:
///
/// **1. Registry (accurate)**: `~/.claude/sessions/<pid>.json` directly records `pid` <->
/// `sessionId`, plus the `status` Claude reports itself. Sessions that match need no
/// guessing at all — their state is taken as-is.
///
/// **2. Guessing (fallback)**: processes the registry doesn't cover (measured: 1 out of
/// 6 live processes missing; older launches won't have one either) fall back to the
/// original rule — if a project has N unclaimed processes left, treat the **N most
/// recently active** unmatched sessions as live.
///
/// Why we can't apply "this directory has a process" to every session under that directory:
/// measured, this would mark all history sessions from the last 14 days as "waiting for
/// you," inflating the count from an expected 11 to 56, making the badge meaningless. The
/// guessing phase can mismatch, but the impact is small: VS Code's jump target is decided
/// by the workspace, not the session.
enum SessionResolver {
    static func resolve(
        _ sessions: [Session],
        processes: [AgentProcess],
        registry: [RegisteredSession] = [],
        now: Date = Date()
    ) -> [ProjectGroup] {
        let byPath = Dictionary(grouping: processes, by: \.cwd)
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let bySessionID = Dictionary(registry.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        // Processes claimed by the registry no longer enter the guessing phase, otherwise
        // the same process could be matched to two sessions.
        let claimed = Set(registry.filter { byPID[$0.pid] != nil }.map(\.pid))

        return Dictionary(grouping: sessions, by: \.projectPath)
            .map { path, items in
                let ordered = items.sorted { $0.lastActivity > $1.lastActivity }
                var spare = (byPath[path] ?? []).filter { !claimed.contains($0.pid) }

                let resolved = ordered.map { session -> ResolvedSession in
                    if let entry = bySessionID[session.id], let process = byPID[entry.pid] {
                        return ResolvedSession(
                            session: session,
                            // A Codex binding carries no status — the lock proves the thread is
                            // open, and the tail says whether the turn is still running.
                            state: entry.status.map(state(for:))
                                ?? session.state(hasLiveProcess: true, now: now),
                            process: process,
                            live: entry.status,
                            exactMatch: true
                        )
                    }
                    // The guess never crosses agents. Measured why: a lock-less `codex`
                    // app-server sits in a real project cwd, so a folder holding one Claude
                    // session and one idle Codex server would otherwise report the Claude
                    // session as live off the back of the wrong process.
                    let index = spare.firstIndex { $0.agent == session.agent }
                    let process = index.map { spare.remove(at: $0) }
                    return ResolvedSession(
                        session: session,
                        state: session.state(hasLiveProcess: process != nil, now: now),
                        process: process,
                        live: nil,
                        exactMatch: false
                    )
                }
                return ProjectGroup(path: path, sessions: resolved)
            }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// `waiting` also counts as "waiting for you" — it's likewise stopped and needs you to
    /// act, just stuck on a dialog instead of a prompt.
    private static func state(for status: LiveStatus) -> SessionState {
        switch status {
        case .busy: .running
        case .idle, .waiting: .awaiting
        }
    }
}
