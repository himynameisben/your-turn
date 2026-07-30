import Foundation

/// A live `claude` process, and which terminal it's running in.
struct ClaudeProcess: Sendable, Identifiable {
    let pid: Int32
    let cwd: String
    /// Full device path, e.g. `/dev/ttys040`. iTerm / Terminal AppleScript uses this to
    /// locate the tab.
    let tty: String?
    let host: TerminalHost
    var id: Int32 { pid }
}

/// The terminal a process lives in. Determines how "jump back to its window" should jump.
enum TerminalHost: Sendable, Equatable {
    /// `port` maps to `~/.claude/ide/<port>.lock`, which reveals which VS Code window it is.
    case vscode(port: String?)
    case iterm
    case appleTerminal
    case other(String?)

    init(termProgram: String?, ssePort: String?) {
        switch termProgram {
        case "vscode": self = .vscode(port: ssePort)
        case "iTerm.app": self = .iterm
        case "Apple_Terminal": self = .appleTerminal
        default: self = .other(termProgram)
        }
    }

    /// The first three are product names and stay as they are in every language. Only the
    /// last-resort case is a description, and it lands in the main window's "Switch back to …"
    /// tooltip, so it gets translated.
    var displayName: String {
        switch self {
        case .vscode: "VS Code"
        case .iterm: "iTerm2"
        case .appleTerminal: "Terminal"
        case .other(let name): name ?? L("Unknown terminal")
        }
    }
}

enum ProcessProbe {
    static func liveProcesses() -> [ClaudeProcess] {
        let pids = runningClaudePIDs()
        guard !pids.isEmpty else { return [] }

        // Sequential is fine: measured ps eww ~190ms, lsof ~19ms — running them concurrently
        // would only save 19ms, not worth introducing cross-thread synchronization for.
        let list = pids.joined(separator: ",")
        let cwds = workingDirectories(pidList: list)
        let envs = terminalHosts(pidList: list)

        return cwds.compactMap { pid, cwd in
            ClaudeProcess(
                pid: pid, cwd: cwd,
                tty: envs[pid]?.tty,
                host: envs[pid]?.host ?? .other(nil)
            )
        }
    }

    private static func runningClaudePIDs() -> [String] {
        guard let out = Shell.run("/usr/bin/pgrep", ["-x", "claude"]) else { return [] }
        return out.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// `lsof -Fpn` prints one field per line, prefixed by type: p=pid, f=fd, n=path.
    /// Batch them in one call with a comma-separated list — measured 19ms for 12 processes
    /// batched vs. 322ms calling one at a time.
    /// (`lsof -c claude` looks more intuitive but measured 0 lines returned — can't use it.)
    private static func workingDirectories(pidList: String) -> [Int32: String] {
        guard let out = Shell.run(
            "/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", pidList, "-Fpn"]
        ) else { return [:] }

        var result: [Int32: String] = [:]
        var current: Int32?
        for line in out.split(whereSeparator: \.isNewline) {
            switch line.first {
            case "p": current = Int32(line.dropFirst())
            case "n": if let pid = current { result[pid] = String(line.dropFirst()) }
            default: break
            }
        }
        return result
    }

    /// `ps eww` prints the full environment after the command, so one call gets every
    /// process's `TERM_PROGRAM` (which kind of terminal) and `CLAUDE_CODE_SSE_PORT`
    /// (which VS Code window).
    private static func terminalHosts(pidList: String) -> [Int32: (tty: String?, host: TerminalHost)] {
        guard let out = Shell.run(
            "/bin/ps", ["eww", "-p", pidList, "-o", "pid=,tty=,command="]
        ) else { return [:] }

        var result: [Int32: (String?, TerminalHost)] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = Int32(fields[0]) else { continue }

            let ttyName = fields[1]
            let tty = ttyName == "??" ? nil : "/dev/\(ttyName)"

            var termProgram: String?
            var ssePort: String?
            for field in fields.dropFirst(2) {
                if field.hasPrefix("TERM_PROGRAM=") {
                    termProgram = String(field.dropFirst("TERM_PROGRAM=".count))
                } else if field.hasPrefix("CLAUDE_CODE_SSE_PORT=") {
                    ssePort = String(field.dropFirst("CLAUDE_CODE_SSE_PORT=".count))
                }
            }
            result[pid] = (tty, TerminalHost(termProgram: termProgram, ssePort: ssePort))
        }
        return result
    }
}

/// Reads `~/.claude/ide/<port>.lock` to find which VS Code workspace an SSE port maps to.
///
/// Why it's needed: a session's cwd can be a subdirectory of the workspace — measured a
/// monorepo session whose cwd sat at `.../repo/apps/web`, while VS Code had `.../repo`
/// open. Opening the cwd directly would open a **new window** instead of focusing the
/// existing one.
enum IDELockReader {
    static func workspace(forPort port: String) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/ide/\(port).lock")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folders = obj["workspaceFolders"] as? [String]
        else { return nil }
        return folders.first
    }
}

enum Shell {
    /// Runs synchronously and captures stdout; always returns nil on failure so callers
    /// degrade gracefully.
    static func run(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// POSIX single-quote escaping, for assembling shell commands.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
