import AppKit
import Foundation

/// A live agent process, and which app it's running in.
struct AgentProcess: Sendable, Identifiable {
    let pid: Int32
    /// Which binary this is. A session may only ever be matched to a process of its own agent
    /// — measured why: a lock-less `codex` app-server sits in a real project cwd
    /// (`/Users/ben/code/ios-app/cat-mine`), so without this the resolver's guessing phase
    /// would hand it to a Claude session in that same folder and call it live.
    let agent: Agent
    let cwd: String
    /// Full device path, e.g. `/dev/ttys040`. iTerm / Terminal AppleScript uses this to
    /// locate the tab.
    let tty: String?
    let host: TerminalHost
    var id: Int32 { pid }
}

/// The app a session lives in. Determines how "jump back to its window" should jump — three
/// tiers, ordered by how precisely the app can be aimed at:
///
/// 1. **`.iterm` / `.appleTerminal`** — AppleScript reaches the individual tab.
/// 2. **`.app` carrying a `port`** — an editor running the Claude Code IDE extension.
///    `~/.claude/ide/<port>.lock` names the workspace it has open, so the right *window* comes
///    up rather than a new one.
/// 3. **`.app` without one** — activate the app and hand it the folder. That is the ceiling for
///    Zed (which ships no AppleScript dictionary) and for standalone terminal emulators.
///
/// Everything below tier 1 keys on `__CFBundleIdentifier`, not on a list of known apps. That's
/// the whole point: VS Code's forks all report `TERM_PROGRAM=vscode`, so a jump keyed on that
/// name opens Visual Studio Code for someone sitting in Cursor.
enum TerminalHost: Sendable, Equatable {
    case iterm
    case appleTerminal
    /// `bundleID` is `__CFBundleIdentifier`, which launchd stamps on an .app and every process
    /// below it — measured on Zed's terminal, on VS Code's terminal, and on Zed's **ACP**
    /// agents, which are the case with nothing else left to read: no `TERM_PROGRAM`, and no tty
    /// at all (measured on a live `codex-acp` tree, the same mechanism Claude Code's adapter
    /// runs through). `name` is the installed app's own name, so the tooltip can say "Cursor".
    case app(bundleID: String, name: String, port: String?)
    /// Nothing to aim at.
    case other(String?)

    init(termProgram: String?, bundleID: String?, ssePort: String?) {
        switch termProgram {
        case "iTerm.app": self = .iterm
        case "Apple_Terminal": self = .appleTerminal

        // tmux is deliberately given up on rather than guessed at. Measured (3.5a): every pane
        // reports TERM_PROGRAM=tmux, masking the real host, and the bundle id that survives is
        // the *server's* birthplace — start the server from Zed, attach later from iTerm, and
        // the panes still say Zed. Confidently activating the wrong app is worse than the
        // Finder fallback.
        case "tmux": self = .other(termProgram)

        default:
            if let bundleID, let name = Self.appName(forBundleID: bundleID) {
                self = .app(bundleID: bundleID, name: name, port: ssePort)
            } else {
                self = .other(termProgram)
            }
        }
    }

    /// A `nil` here means LaunchServices doesn't know the id, which is also the one case where
    /// there would be nothing to open — so it falls through to `.other` together.
    private static func appName(forBundleID id: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?
            .deletingPathExtension().lastPathComponent
    }

    /// The two terminals are product names and stay as they are in every language; `.app` says
    /// whatever the installed bundle is called. Only the last-resort case is a description, and
    /// it lands in the main window's "Switch back to …" tooltip, so it gets translated.
    var displayName: String {
        switch self {
        case .iterm: "iTerm2"
        case .appleTerminal: "Terminal"
        case .app(_, let name, _): name
        case .other(let name): name ?? L("Unknown terminal")
        }
    }
}

enum ProcessProbe {
    /// One `pgrep` per agent, then a single batched `lsof` and `ps` covering both — the two
    /// expensive calls stay at one apiece no matter how many agents are installed.
    static func liveProcesses() -> [AgentProcess] {
        var agentByPID: [Int32: Agent] = [:]
        for agent in Agent.allCases {
            for pid in runningPIDs(named: agent.processName) {
                if let id = Int32(pid) { agentByPID[id] = agent }
            }
        }
        guard !agentByPID.isEmpty else { return [] }

        // Sequential is fine: measured ps eww ~190ms, lsof ~19ms — running them concurrently
        // would only save 19ms, not worth introducing cross-thread synchronization for.
        let list = agentByPID.keys.map(String.init).joined(separator: ",")
        let cwds = workingDirectories(pidList: list)
        let envs = terminalHosts(pidList: list)

        return cwds.compactMap { pid, cwd in
            guard let agent = agentByPID[pid] else { return nil }
            return AgentProcess(
                pid: pid, agent: agent, cwd: cwd,
                tty: envs[pid]?.tty,
                host: envs[pid]?.host ?? .other(nil)
            )
        }
    }

    static func runningPIDs(named name: String) -> [String] {
        guard let out = Shell.run("/usr/bin/pgrep", ["-x", name]) else { return [] }
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
    /// process's `TERM_PROGRAM` (which kind of terminal), `CLAUDE_CODE_SSE_PORT`
    /// (which VS Code window) and `__CFBundleIdentifier` (which GUI app it descends from,
    /// the only clue an ACP session leaves).
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
            var bundleID: String?
            for field in fields.dropFirst(2) {
                if field.hasPrefix("TERM_PROGRAM=") {
                    termProgram = String(field.dropFirst("TERM_PROGRAM=".count))
                } else if field.hasPrefix("CLAUDE_CODE_SSE_PORT=") {
                    ssePort = String(field.dropFirst("CLAUDE_CODE_SSE_PORT=".count))
                } else if field.hasPrefix("__CFBundleIdentifier=") {
                    bundleID = String(field.dropFirst("__CFBundleIdentifier=".count))
                }
            }
            result[pid] = (
                tty, TerminalHost(termProgram: termProgram, bundleID: bundleID, ssePort: ssePort)
            )
        }
        return result
    }
}

/// Reads `~/.claude/ide/<port>.lock` to find which workspace an SSE port maps to.
///
/// Why it's needed: a session's cwd can be a subdirectory of the workspace — measured a
/// monorepo session whose cwd sat at `.../repo/apps/web`, while VS Code had `.../repo`
/// open. Opening the cwd directly would open a **new window** instead of focusing the
/// existing one.
///
/// The file is written by the editor's Claude Code extension, so it's the same shape whatever
/// the editor is — verified against the extension's own source
/// (`anthropic.claude-code-2.1.233`), which writes `{pid, workspaceFolders, ideName, …}` with
/// `ideName` set to `vscode.env.appName`. That name goes unread here: `__CFBundleIdentifier`
/// answers "which app" exactly and for every host, not just the ones shipping an extension.
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
