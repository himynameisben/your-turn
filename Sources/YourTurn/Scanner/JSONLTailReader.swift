import Foundation

/// Reads summary info from the tail of a session JSONL file.
///
/// Why only read the tail: `~/.claude/projects` measured 696MB across 496 files, with the
/// largest single file at 37.5MB — parsing the whole thing isn't feasible. Measured: reading
/// just the last 64KB already captures 93% of `ai-title` and 72% of `away_summary`; the misses
/// are all short sessions under 2KB that never had a title to begin with.
enum JSONLTailReader {
    static let tailBytes = 64 * 1024

    struct Result: Sendable {
        var title: String?
        var summary: String?
        var lastPrompt: String?
        var cwd: String?
        var gitBranch: String?
        var sessionId: String?
        /// The timestamp the last conversation record wrote itself. **Do not use the file
        /// mtime for this**: Claude Code rewrites the metadata records at the tail of the
        /// file even when you haven't touched it (`last-prompt` / `ai-title` / `mode` /
        /// `permission-mode` carry no timestamp) — measured across 118 sessions, 71% had an
        /// mtime more than 5 minutes later than the last message, with a median lag of 3.6
        /// hours and the worst case 35 days.
        var lastTimestamp: Date?
        var tail: TailMarker = .unknown
    }

    static func scan(_ url: URL) -> Result? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        var lines = String(decoding: data, as: UTF8.self).split(
            separator: "\n", omittingEmptySubsequences: true
        )
        // Seeking in from the middle almost always cuts the first line in half — discard it.
        if offset > 0, !lines.isEmpty { lines.removeFirst() }

        var result = Result()
        for line in lines {
            guard let obj = parse(line) else { continue }
            let type = obj["type"] as? String
            let subtype = obj["subtype"] as? String

            switch type {
            case "ai-title":
                result.title = obj["aiTitle"] as? String ?? result.title
            case "last-prompt":
                result.lastPrompt = obj["lastPrompt"] as? String ?? result.lastPrompt
            default:
                break
            }
            if subtype == "away_summary", let content = obj["content"] as? String {
                result.summary = content
            }

            // Only genuine conversation records should affect the turn-ended decision;
            // auxiliary records like attachment / mode / file-history-* are interleaved
            // and must not be used for it.
            guard let type, ["user", "assistant", "system"].contains(type) else { continue }
            result.cwd = obj["cwd"] as? String ?? result.cwd
            result.gitBranch = obj["gitBranch"] as? String ?? result.gitBranch
            result.sessionId = obj["sessionId"] as? String ?? result.sessionId
            if let stamp = obj["timestamp"] as? String, let date = parseTimestamp(stamp) {
                result.lastTimestamp = date
            }
            result.tail = (type == "system" && (subtype == "turn_duration" || subtype == "away_summary"))
                ? .turnEnded : .inProgress
        }
        return result
    }

    private static func parseTimestamp(_ s: String) -> Date? { ISOTimestamp.parse(s) }

    /// Using JSONSerialization instead of Codable: JSONL is Claude Code's internal format
    /// (currently v2.1.220) and field types may change across versions. `as? String` naturally
    /// returns nil on a type mismatch, instead of failing the whole parse the way Codable
    /// would over a single field's type mismatch.
    private static func parse(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }
}
