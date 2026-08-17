import Foundation

/// Finds which Codex threads are open, and in which process.
///
/// Codex has no equivalent of `~/.claude/sessions/<pid>.json`, and at first glance that looks
/// like a downgrade to the guessing the Claude path needs as a fallback. It isn't: a live
/// thread holds an open file descriptor on `~/.codex/thread-writer-locks/<thread-id>.lock`,
/// and the file's *name is the thread id*. So `lsof` on the Codex processes yields the pid ↔
/// thread mapping directly, with no heuristic anywhere — measured 10 held locks across 4
/// processes, every one resolving to a row in `threads`.
///
/// It is also strictly better evidence than a registry file, because the kernel owns it: an
/// entry cannot outlive the process the way a `-9`'d Claude session leaves its JSON behind.
enum CodexLockProbe {
    static let locksPath = CodexScanner.root
        .appending(path: "thread-writer-locks", directoryHint: .isDirectory)
        .path

    /// Returns one `RegisteredSession` per open thread, so `SessionResolver` can consume these
    /// on the exact-match path it already has for Claude's registry.
    ///
    /// `status` is deliberately `nil`: Codex reports nothing about itself, so the state is
    /// inferred from the rollout tail plus the clock — the same route an unregistered Claude
    /// session takes.
    /// `pids` comes from the probe that already ran, so Codex is never `pgrep`ed twice.
    static func openThreads(pids: [Int32], cwdByThread: [String: String]) -> [RegisteredSession] {
        guard !pids.isEmpty else { return [] }

        // Batched by pid rather than `lsof +D <dir>`: measured 84ms against 152ms, and it's
        // the same trick already documented in `ProcessProbe.workingDirectories`.
        guard let out = Shell.run(
            "/usr/sbin/lsof", ["-a", "-p", pids.map(String.init).joined(separator: ","), "-Fpn"]
        ) else { return [] }

        var result: [RegisteredSession] = []
        var current: Int32?
        for line in out.split(whereSeparator: \.isNewline) {
            switch line.first {
            case "p":
                current = Int32(line.dropFirst())
            case "n":
                let path = line.dropFirst()
                guard let pid = current, path.hasPrefix(locksPath),
                      let threadID = threadID(fromLockPath: path),
                      let cwd = cwdByThread[threadID]
                else { continue }
                result.append(
                    RegisteredSession(pid: pid, sessionId: threadID, cwd: cwd, status: nil)
                )
            default:
                break
            }
        }
        return result
    }

    /// `.../thread-writer-locks/<uuid>.lock` → `<uuid>`. The directory also holds a
    /// `.coordination.lock`, which names no thread and drops out for want of a matching row.
    private static func threadID(fromLockPath path: Substring) -> String? {
        let name = (String(path) as NSString).lastPathComponent
        guard name.hasSuffix(".lock") else { return nil }
        let id = String(name.dropLast(".lock".count))
        return id.isEmpty ? nil : id
    }
}
