import Foundation

/// How much of your Codex allowance is gone, and when it comes back.
///
/// **Deliberately not dollars.** The rest of the Usage tab reconstructs a bill, because Claude
/// Code's transcripts carry per-request token counts that a price table turns into real money.
/// Neither half of that holds for Codex. Its `total_token_usage` is a **running total for the
/// whole thread**, re-emitted on every turn, so the per-request deduplication the Claude
/// pipeline is built around has nothing to deduplicate — summing the rows would multiply the
/// thread's usage by its number of turns. And the account is a subscription, so a dollar figure
/// derived from tokens would describe a bill nobody receives.
///
/// What Codex does report, and what a subscriber actually wants, is the allowance: measured
/// `used_percent` 46.0 against a `window_minutes` of 10080 (7 days) with a `resets_at` stamp.
/// That is the whole model here — one number, one clock.
struct CodexQuota: Sendable, Equatable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date?
    /// When the reading was taken. A quota is only as good as its timestamp: it comes from the
    /// last turn of the most recent thread, so an idle week makes it stale, and the page says so
    /// rather than presenting a week-old number as current.
    let observedAt: Date

    /// Reads as an adjective, not a duration — it lands inside "of your … allowance", where
    /// "7 days allowance" is wrong in English and "7-day allowance" is right. zh-Hant needs no
    /// such distinction and maps both to 天.
    var windowLabel: String {
        let days = windowMinutes / 1440
        if days >= 1 { return L("\(days)-day") }
        return L("\(max(1, windowMinutes / 60))-hour")
    }
}

enum CodexQuotaReader {
    /// Reads the newest `token_count` record out of the most recently touched Codex threads.
    ///
    /// Walks the threads newest-first and stops at the first one that yields a reading, rather
    /// than scanning all of them: the allowance is per account, not per thread, so the newest
    /// observation is the only one that isn't already superseded. The loop exists only because
    /// a thread can end without a `token_count` — a fresh one that never completed a turn.
    static func read(sessions: [Session], limit: Int = 8) -> CodexQuota? {
        let candidates = sessions
            .filter { $0.agent == .codex }
            .sorted { $0.lastActivity > $1.lastActivity }
            .prefix(limit)

        for session in candidates {
            let path = session.fileURL.path
            guard !path.isEmpty,
                  let quota = RolloutTailReader.rateLimit(path, observedAt: session.lastActivity)
            else { continue }
            return quota
        }
        return nil
    }
}

extension RolloutTailReader {
    /// The last `token_count` record's `rate_limits.primary`, if the tail holds one.
    ///
    /// Separate from `scan` because it answers a different question for a different page, and
    /// the session list must not pay for it — measured 48 Codex threads scanned in 16ms, and
    /// that budget is why the Usage tab reads at most a handful of files instead of all of them.
    static func rateLimit(_ path: String, observedAt: Date) -> CodexQuota? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }

        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }

        var latest: CodexQuota?
        for line in lines {
            // Same 256-byte window as `scan`, same reason.
            let head = String(decoding: line.utf8.prefix(headBytes), as: UTF8.self)
            guard head.contains("token_count") else { continue }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let limits = payload["rate_limits"] as? [String: Any],
                  let primary = limits["primary"] as? [String: Any],
                  let used = primary["used_percent"] as? Double
            else { continue }

            latest = CodexQuota(
                usedPercent: used,
                windowMinutes: (primary["window_minutes"] as? NSNumber)?.intValue ?? 0,
                resetsAt: (primary["resets_at"] as? NSNumber)
                    .map { Date(timeIntervalSince1970: $0.doubleValue) },
                observedAt: observedAt
            )
        }
        return latest
    }
}
