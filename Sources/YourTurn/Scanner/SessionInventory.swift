import Foundation

/// The one place the two agents' scans are combined.
///
/// It exists so `--dump` and the app cannot drift. The CLI is this project's only way to check
/// a session-layer change, and a verification tool that assembles its inputs differently from
/// the thing it verifies is worse than no tool — it would have gone on reporting a healthy
/// Claude-only list while the window showed something else entirely.
enum SessionInventory {
    struct Snapshot: Sendable {
        let sessions: [Session]
        let processes: [AgentProcess]
        let registry: [RegisteredSession]
        /// Split per agent, because the two read completely different things off disk and a
        /// single number would hide which one regressed.
        let claudeScanTime: TimeInterval
        let codexScanTime: TimeInterval
        let probeTime: TimeInterval
        var scanTime: TimeInterval { claudeScanTime + codexScanTime }
    }

    static func collect() -> Snapshot {
        let claudeStarted = Date()
        let claudeSessions = SessionScanner.scan()
        let claudeScanTime = Date().timeIntervalSince(claudeStarted)

        let codexStarted = Date()
        let codexSessions = CodexScanner.scan()
        let codexScanTime = Date().timeIntervalSince(codexStarted)

        let sessions = claudeSessions + codexSessions

        let probeStarted = Date()
        let processes = ProcessProbe.liveProcesses()
        // Codex's lock file names the thread and nothing else, so the cwd has to come back
        // from the scan that just ran.
        let cwds = Dictionary(
            sessions.lazy.filter { $0.agent == .codex }.map { ($0.id, $0.projectPath) },
            uniquingKeysWith: { a, _ in a }
        )
        let registry = SessionRegistry.read(livePIDs: Set(processes.map(\.pid)))
            + CodexLockProbe.openThreads(
                pids: processes.filter { $0.agent == .codex }.map(\.pid),
                cwdByThread: cwds
            )
        let probeTime = Date().timeIntervalSince(probeStarted)

        return Snapshot(
            sessions: sessions,
            processes: processes,
            registry: registry,
            claudeScanTime: claudeScanTime,
            codexScanTime: codexScanTime,
            probeTime: probeTime
        )
    }

    /// The finished list, exactly as both the window and `--dump` see it.
    static func groups(now: Date = Date()) -> (groups: [ProjectGroup], snapshot: Snapshot) {
        let snapshot = collect()
        return (
            SessionResolver.resolve(
                snapshot.sessions,
                processes: snapshot.processes,
                registry: snapshot.registry,
                now: now
            ),
            snapshot
        )
    }
}
