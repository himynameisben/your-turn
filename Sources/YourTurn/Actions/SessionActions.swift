import AppKit
import Foundation

enum TerminalApp: String, CaseIterable, Identifiable, Sendable {
    case terminal = "Terminal"
    case iterm = "iTerm"

    var id: String { rawValue }
    var displayName: String { self == .terminal ? "Terminal" : "iTerm2" }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    var bundleID: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iterm: "com.googlecode.iterm2"
        }
    }

    /// The two have different AppleScript interfaces: Terminal uses `do script`, while
    /// iTerm needs a new window opened first, then `write text`.
    func script(running command: String) -> String {
        let literal = AppleScript.quote(command)
        switch self {
        case .terminal:
            return """
            tell application "Terminal"
                activate
                do script \(literal)
            end tell
            """
        case .iterm:
            return """
            tell application "iTerm"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text \(literal)
                end tell
            end tell
            """
        }
    }
}

enum EditorApp: String, CaseIterable, Identifiable, Sendable {
    case vscode = "Visual Studio Code"
    case cursor = "Cursor"
    case sublime = "Sublime Text"
    case zed = "Zed"

    var id: String { rawValue }
    var displayName: String { rawValue }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    var bundleID: String {
        switch self {
        case .vscode: "com.microsoft.VSCode"
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .sublime: "com.sublimetext.4"
        case .zed: "dev.zed.Zed"
        }
    }
}

enum SessionActions {
    /// Main entry point for "jump to it".
    ///
    /// Key branch: while a session is still alive you **must not** `--resume` it — that
    /// spawns a second process for the same session. Instead, switch back to whichever
    /// terminal window/tab it's already running in. Only a session whose terminal has
    /// closed needs a new window to resume in.
    static func jump(_ item: ResolvedSession, fallback: TerminalApp) {
        guard let process = item.process else {
            resume(item.session, in: fallback)
            return
        }
        focus(process, session: item.session)
    }

    /// Switches focus to the terminal the process is running in.
    private static func focus(_ process: ClaudeProcess, session: Session) {
        switch process.host {
        case .vscode(let port):
            // Must use the workspace from the lock file, not the session's cwd: cwd can be
            // a subdirectory (observed fanproof's session cwd as .../fanproof/apps/liff),
            // and opening a subdirectory spawns a new window instead of focusing the
            // existing one.
            let folder = port.flatMap(IDELockReader.workspace) ?? session.projectPath
            _ = Shell.run("/usr/bin/open", ["-a", "Visual Studio Code", folder])

        case .iterm:
            AppleScript.run(itermFocusScript(title: session.title, tty: process.tty))

        case .appleTerminal:
            guard let tty = process.tty else { return }
            AppleScript.run(terminalFocusScript(tty: tty))

        case .other:
            // Unrecognized terminals (Ghostty, Warp, etc.) have no reliable AppleScript way
            // to locate a window — at least open the project folder instead of failing
            // silently.
            _ = Shell.run("/usr/bin/open", [session.projectPath])
        }
    }

    /// Opens a new terminal window, cds into the project directory, and resumes the session.
    static func resume(_ session: Session, in terminal: TerminalApp) {
        guard isSafeSessionID(session.id) else { return }
        let command = "cd \(Shell.quote(session.projectPath)) && claude --resume \(session.id)"
        AppleScript.run(terminal.script(running: command))
    }

    /// Matches on tab title first, falling back to tty.
    ///
    /// Why title takes priority: Claude Code sets the tab title to the session's ai-title
    /// (observed iTerm tab name: "✳ Check Mac disk I/O stats (node)"), which is a
    /// session-specific identifier; whereas tty comes from `SessionResolver`'s top-N
    /// heuristic matching, which picks the wrong session when a project has multiple
    /// sessions open at once — observed two claude-tmp sessions with identical mtimes,
    /// making sort order effectively random, so tty-based matching jumps to the wrong tab.
    private static func itermFocusScript(title: String?, tty: String?) -> String {
        let titleLiteral = AppleScript.quote(title ?? "")
        let ttyLiteral = AppleScript.quote(tty ?? "")
        return """
        tell application "iTerm"
            activate
            set wantTitle to \(titleLiteral)
            set wantTTY to \(ttyLiteral)
            if wantTitle is not "" then
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if (name of s) contains wantTitle then
                                select w
                                select t
                                select s
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end if
            if wantTTY is not "" then
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if (tty of s) is wantTTY then
                                select w
                                select t
                                select s
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end if
        end tell
        """
    }

    /// Terminal.app's tty property lives on the tab (not the session).
    private static func terminalFocusScript(tty: String) -> String {
        """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if (tty of t) is \(AppleScript.quote(tty)) then
                        set selected tab of w to t
                        set index of w to 1
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
    }

    static func openInEditor(_ session: Session, using editor: EditorApp) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleID)
        else { return }
        let folder = URL(fileURLWithPath: session.projectPath)
        NSWorkspace.shared.open(
            [folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()
        )
    }

    static func revealInFinder(_ session: Session) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.projectPath)
    }

    static func copyResumeCommand(_ session: Session) {
        let command = "cd \(Shell.quote(session.projectPath)) && claude --resume \(session.id)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// sessionId comes from parsing an external file and gets spliced into a shell command,
    /// so non-UUID characters are rejected first.
    private static func isSafeSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isHexDigit || $0 == "-" }
    }
}

enum AppleScript {
    static func run(_ source: String) {
        _ = Shell.run("/usr/bin/osascript", ["-e", source])
    }

    /// Produces an AppleScript string literal (including the surrounding double quotes).
    static func quote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
