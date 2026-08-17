import Foundation

/// Which coding agent wrote a session.
///
/// The two keep entirely separate homes on disk — `~/.claude` and `~/.codex` — and agree on
/// almost nothing about how they record a session, so each gets its own scanner. What they
/// *do* share is everything downstream: a session belongs to a cwd, runs in a process, and
/// that process belongs to an app you can be sent back to.
///
/// Product names, so they read the same in every language and stay out of `Localizable.strings`.
enum Agent: String, Sendable, Equatable, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// The command that picks a finished session back up, minus the id. Claude spells it with
    /// a flag, Codex with a subcommand — the one place the two CLIs disagree that reaches a
    /// user-visible action.
    var resumeCommand: String {
        switch self {
        case .claude: "claude --resume"
        case .codex: "codex resume"
        }
    }

    /// The process name each agent runs under, for `pgrep -x`.
    var processName: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        }
    }
}
