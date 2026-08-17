import Foundation

/// Reads the last 64KB of a Codex rollout to find what the thread is *doing*.
///
/// Same 64KB as `JSONLTailReader`, for the same reason and with the same result. Measured over
/// 459 rollouts totalling 5.4GB (one of them 1.0MB on its own): the tail alone determines the
/// turn state for **98%** of them and carries the agent's closing message for **93%**. Reading
/// whole files would buy 2 percentage points for four orders of magnitude more I/O.
///
/// The `threads` table already holds the title, cwd, branch and first prompt, so — unlike the
/// Claude reader — none of that is dug out here. This answers exactly two questions: has the
/// current turn ended, and what was said last.
enum RolloutTailReader {
    struct Scan: Sendable {
        let marker: TailMarker
        let lastAgentMessage: String?
        let lastUserMessage: String?
    }

    static let tailBytes = 64 * 1024
    /// How much of each record to search for its type. Measured maximum position of the
    /// `"payload":{"type":"` discriminator: 82 bytes.
    static let headBytes = 256

    static func scan(_ path: String) -> Scan? {
        guard !path.isEmpty, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }

        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        // A non-zero offset lands mid-record, so the first line is a fragment.
        if offset > 0, !lines.isEmpty { lines.removeFirst() }

        var marker: TailMarker = .unknown
        var lastAgent: String?
        var lastUser: String?

        for line in lines {
            // The cheap reject first: these files are mostly reasoning and tool output, and
            // only a few record types matter. Measured 169 response_item / 163 event_msg in a
            // single 1MB rollout, of which 6 are turn boundaries.
            //
            // Only the first 256 bytes are searched, and that is what makes the reject cheap.
            // Every record is `{"timestamp":…,"type":…,"payload":{"type":"X"…`, and measured
            // over 1,327 records the discriminator never starts later than **82 bytes** in, so
            // a 256-byte window loses nothing. Scanning whole lines instead measured 207ms per
            // 48 files against 20ms — lines run to tens of KB of reasoning and tool output, and
            // Swift's `contains` walks every one of those bytes for grapheme correctness. The
            // window also removes a class of false positive: prose that happens to quote
            // "user_message" can no longer masquerade as the record type.
            let head = String(decoding: line.utf8.prefix(headBytes), as: UTF8.self)
            guard head.contains("task_started") || head.contains("task_complete")
                || head.contains("turn_aborted") || head.contains("user_message")
            else { continue }

            guard let payload = payload(of: line), let type = payload["type"] as? String
            else { continue }

            switch type {
            case "task_started":
                marker = .inProgress
            case "task_complete":
                marker = .turnEnded
                if let message = payload["last_agent_message"] as? String, !message.isEmpty {
                    lastAgent = message
                }
            case "turn_aborted":
                // An interrupt ends the turn just as firmly as a completion — the agent has
                // stopped and it is your move. Measured 81 across all rollouts.
                marker = .turnEnded
            case "user_message":
                if let message = payload["message"] as? String, !message.isEmpty {
                    lastUser = message
                }
            default:
                break
            }
        }
        return Scan(marker: marker, lastAgentMessage: lastAgent, lastUserMessage: lastUser)
    }

    /// Every rollout line is `{"timestamp":…,"type":…,"payload":{…}}`; the discriminator that
    /// matters lives one level down, inside `payload`.
    private static func payload(of line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["payload"] as? [String: Any]
    }
}
