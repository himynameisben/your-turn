import Foundation

/// The type of the last message record at the tail of a session's JSONL, used to tell
/// whether a turn has wrapped up.
///
/// Claude Code writes `system/turn_duration` at the end of every turn, then (if you've
/// stepped away) writes `system/away_summary`. So "the tail is a system wrap-up record"
/// is equivalent to "Claude has stopped."
///
/// Codex spells the same thing with explicit events and is easier to read for it: a turn opens
/// with `task_started` and closes with `task_complete` or `turn_aborted`, so the last of those
/// three *is* the marker. Measured across 459 rollouts: 2,615 starts against 2,525 completes
/// plus 81 aborts — the 9 left over are the crashes, which land on `.inProgress` and then age
/// out of `running` on the clock, exactly like a Claude session that died mid-turn.
enum TailMarker: Sendable, Equatable {
    /// The turn has ended (`turn_duration` / `away_summary`; `task_complete` / `turn_aborted`)
    /// — the agent is stopped, waiting for you
    case turnEnded
    /// The tail is still a user/assistant message, or an unclosed `task_started`
    case inProgress
    /// No message record found within the tail 64KB
    case unknown
}

/// The sole signal is "is the terminal still open?" — not the conversation content.
///
/// Why not look at the content: `away_summary` is a **snapshot** — Claude writes "next step:
/// decide whether to delete X," you finish it the next day, and that text stays frozen there
/// forever. Measured: of 69 sessions with a "pending" summary, 50 were 3+ days old, and the
/// vast majority were already done. Using it as the basis for status would pile up an
/// alarming and meaningless number.
///
/// So: **a closed terminal = the thing is done**. To go looking for old ones, use the resume list.
enum SessionState: Sendable, Equatable {
    /// Claude is working — nothing for you to do
    case running
    /// Claude has stopped, the terminal is still open — **this is the star of the product**
    case awaiting
    /// The terminal has closed. Treated as done; doesn't take up the primary UI, only
    /// stays in the resume list
    case finished

    var label: String {
        switch self {
        case .running: "Running"
        case .awaiting: "Waiting for you"
        case .finished: "Done"
        }
    }

    /// The terminal is still open — needs to show up in the primary UI.
    var isActive: Bool { self != .finished }
}

struct Session: Identifiable, Sendable {
    let id: String
    /// Which agent wrote it. Decides the resume command and the row's badge; everything else
    /// downstream treats the two identically.
    let agent: Agent
    let fileURL: URL
    let projectPath: String
    let gitBranch: String?
    /// The session title Claude auto-generates (`ai-title`)
    let title: String?
    /// The progress summary Claude writes when you step away (`away_summary`), with the next step
    let summary: String?
    /// Fallback for when there's no summary
    let lastPrompt: String?
    let lastActivity: Date
    let tail: TailMarker

    var projectName: String {
        URL(fileURLWithPath: projectPath).lastPathComponent
    }

    /// Short sessions without an ai-title fall back to showing the last prompt.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let lastPrompt, !lastPrompt.isEmpty { return Self.firstLine(lastPrompt) }
        // Also reaches `--dump`, which is otherwise all-English; a translated placeholder in a
        // debug listing is a smaller wart than an English one sitting in a Chinese window.
        return L("(Untitled)")
    }

    /// The last thing you said to it (`last-prompt`).
    ///
    /// Measured: 99% of 118 sessions have this, more reliable than `away_summary` (72%), and
    /// it's the most direct evidence of "what you're doing" — "switch to the gateway-first
    /// version," "okay, go ahead and handle it." Newlines are collapsed to spaces: prompts
    /// are often multi-line pastes, and the list only needs it to read like one sentence.
    var youSaid: String? {
        guard let lastPrompt else { return nil }
        let flattened = lastPrompt
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return flattened.isEmpty ? nil : flattened
    }

    /// The body text shown when a card expands: prefers away_summary, falls back to last-prompt.
    var displayDetail: String? {
        if let summary, !summary.isEmpty { return SummaryText.clean(summary) }
        if let lastPrompt, !lastPrompt.isEmpty { return lastPrompt }
        return nil
    }

    /// The line shown in the list — this is the reason the user opened the app.
    var nextAction: NextAction {
        SummaryText.nextAction(from: summary)
    }

    /// Decided from three combined signals: tail record type + time elapsed + whether the
    /// project still has a live process.
    func state(hasLiveProcess: Bool, now: Date = Date()) -> SessionState {
        guard hasLiveProcess else { return .finished }
        let age = now.timeIntervalSince(lastActivity)
        return (tail != .turnEnded && age < Self.runningWindow) ? .running : .awaiting
    }

    /// 3 days is the natural cutoff in the data: measured 13 within the last hour, 4 today,
    /// 8 at 1-3 days, but 3-7 days jumps to 54. Anything past this line should fade from view.
    func isRecent(now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastActivity) < Self.recentWindow
    }

    static let recentWindow: TimeInterval = 3 * 86_400
    static let runningWindow: TimeInterval = 60

    private static func firstLine(_ s: String) -> String {
        s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? s
    }
}
