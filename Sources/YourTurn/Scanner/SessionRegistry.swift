import Foundation

/// The live status Claude Code reports about itself.
///
/// Values read from the CLI binary (2.1.220): `busy` / `idle` / `waiting`, where `waiting`
/// carries an extra `waitingFor` (`"input needed"`, `"dialog open"`, `"sandbox request"`,
/// `"worker request"`, or the dialog's own title).
enum LiveStatus: Sendable, Equatable {
    /// Claude is running
    case busy
    /// Finished running, waiting for your next message
    case idle
    /// Stuck on a dialog — it can't proceed until you answer
    case waiting(String?)

    init(status: String?, waitingFor: String?) {
        switch status {
        case "busy": self = .busy
        case "waiting": self = .waiting(waitingFor)
        default: self = .idle
        }
    }
}

/// One entry in `~/.claude/sessions/<pid>.json`.
struct RegisteredSession: Sendable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let status: LiveStatus
}

/// Reads Claude Code's live session registry.
///
/// Why this matters: before this existed, there was no way to map a PID to a sessionId
/// (`ps eww` has no sessionId, and the process doesn't hold a file handle on the JSONL), so
/// the only option was guessing — "a project has N live processes, so treat its N most
/// recently active sessions as live." This file writes out `pid` and `sessionId` directly,
/// plus the status Claude reports about itself, so the guess can be demoted to a fallback.
///
/// But **it can't be the only source**: measured 6 live `claude` processes with only 5
/// registered (the missing one was an SDK/agent-style session), and sessions started by
/// older versions won't be registered either.
enum SessionRegistry {
    static let root = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: ".claude/sessions", directoryHint: .isDirectory)

    /// Only returns entries whose PID is still alive — the file is left behind as an orphan
    /// when the process is killed with -9.
    static func read(livePIDs: Set<Int32>) -> [RegisteredSession] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return files.compactMap { url -> RegisteredSession? in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (obj["pid"] as? NSNumber)?.int32Value, livePIDs.contains(pid),
                  let sessionId = obj["sessionId"] as? String,
                  let cwd = obj["cwd"] as? String
            else { return nil }

            return RegisteredSession(
                pid: pid,
                sessionId: sessionId,
                cwd: cwd,
                status: LiveStatus(
                    status: obj["status"] as? String,
                    waitingFor: obj["waitingFor"] as? String
                )
            )
        }
    }
}
