import Foundation

/// How much of an agent's allowance is left, and when it comes back.
///
/// **Deliberately not dollars, for either agent.** The rest of the Usage tab reconstructs a bill,
/// because Claude Code's transcripts carry per-request token counts that a price table turns into
/// real money. That reasoning doesn't reach here. Codex's `total_token_usage` is a running total
/// for the whole thread, re-emitted every turn, so the per-request deduplication the Claude
/// pipeline is built around has nothing to deduplicate — summing the rows would multiply a
/// thread's usage by its number of turns. And both accounts are subscriptions, so a dollar figure
/// derived from tokens describes a bill nobody receives. What a subscriber actually wants is the
/// allowance: a percentage, a window, and a clock.
///
/// **Stated as what's left, not what's gone.** Both agents report the opposite — Claude Code's own
/// footer says "You've used 82% of your weekly limit", Codex's rollout says `used_percent` — but
/// the question this page exists to answer is whether there's room to start something, and
/// "18% left" answers it without arithmetic.
struct AgentQuota: Sendable, Equatable, Identifiable {
    let agent: Agent
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date?
    /// When the reading was taken. A quota is only as good as its timestamp: neither agent is
    /// queried live — Codex's comes off the last turn on disk, Claude's off the last status line
    /// render — so a week away from an agent leaves a week-old number, and the row says so rather
    /// than presenting it as current.
    let observedAt: Date

    /// One row per agent per window, which is what keeps a `ForEach` stable while a rescan swaps
    /// the values underneath it.
    var id: String { "\(agent.rawValue)-\(windowMinutes)" }

    var remainingPercent: Double { min(max(100 - usedPercent, 0), 100) }

    /// The one threshold on this page. Below it the bar goes amber — the same colour the session
    /// chips use for "your turn", and for the same reason: it's the point where you need to know.
    var isLow: Bool { remainingPercent < 20 }

    /// When the window comes back, as a wall clock rather than a countdown.
    ///
    /// The countdown ("in 1d") is the right register for the masthead, where the question is
    /// whether to start something now. On the Usage tab the question is when you get your
    /// allowance back, and "in 1d" can't answer it — the weekly window resets at a fixed hour,
    /// and knowing it's 8am tomorrow rather than some point during the day is the difference
    /// between planning around it and waiting for it.
    ///
    /// Formatting puts it in the reader's own zone by construction: `resetsAt` is an absolute
    /// instant, built from a UTC stamp on Claude's side (`2026-08-19T00:00:00Z`) and a Unix
    /// stamp on Codex's, and neither is a time anybody's day is organised around.
    ///
    /// Split into a date and a time so English can say "Aug 19 at 8:00 AM" rather than the "at
    /// Aug 19, 8:00 AM" a single field would force; the same two pieces read as "8月19日 上午8:00"
    /// in zh-Hant. And templates rather than fixed patterns: `jm` resolves to whichever of the
    /// 12- and 24-hour clock the locale uses, which a hardcoded `HH:mm` would silently override.
    func resetsText(now: Date, calendar: Calendar = .current) -> String? {
        guard let resetsAt else { return nil }
        let time = Self.formatted(resetsAt, template: "jm")
        guard !calendar.isDate(resetsAt, inSameDayAs: now) else { return L("Resets at \(time)") }
        return L("Resets \(Self.formatted(resetsAt, template: "MMMd")) at \(time)")
    }

    /// `Localization.locale`, not `Locale.current` — the same rule the masthead's dateline
    /// follows. An English UI on a Taiwanese machine must not print 上午 under an English headline.
    private static func formatted(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Localization.locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// Reads as an adjective, not a duration — it lands inside "left of your … allowance", where
    /// "7 days allowance" is wrong in English and "7-day allowance" is right. zh-Hant needs no
    /// such distinction and maps both to 天.
    var windowLabel: String {
        let days = windowMinutes / 1440
        if days >= 1 { return L("\(days)-day") }
        return L("\(max(1, windowMinutes / 60))-hour")
    }
}

// MARK: - Claude

/// Reads whatever `statusline-bridge.sh` last wrote.
///
/// A single small file, so there is no scan and no cache — the expensive half of this page is
/// `UsageScanner`, and this costs one `Data(contentsOf:)` next to it.
enum ClaudeQuotaReader {
    /// The two windows Claude Code reports, in the order they matter: the five-hour one is what
    /// stops you in the next hour, the weekly one is what stops you on Thursday.
    ///
    /// Their lengths are written here rather than read from the payload because the payload
    /// doesn't carry them — the windows are identified by name (`five_hour` / `seven_day`) and
    /// nothing else. Measured against `/api/oauth/usage` on the same account at the same moment:
    /// 44 / 82 here against 43 / 82 there, with matching reset stamps.
    private static let windows: [(key: String, minutes: Int)] = [
        ("five_hour", 5 * 60),
        ("seven_day", 7 * 24 * 60),
    ]

    static func read() -> [AgentQuota] {
        guard let data = try? Data(contentsOf: StatusLineBridge.payloadURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = object["rate_limits"] as? [String: Any]
        else { return [] }

        let observed = (object["observed_at"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()

        return windows.compactMap { window in
            guard let entry = limits[window.key] as? [String: Any],
                  let used = (entry["used_percentage"] as? NSNumber)?.doubleValue
            else { return nil }
            return AgentQuota(
                agent: .claude,
                usedPercent: used,
                windowMinutes: window.minutes,
                resetsAt: (entry["resets_at"] as? NSNumber)
                    .map { Date(timeIntervalSince1970: $0.doubleValue) },
                observedAt: observed
            )
        }
    }
}

// MARK: - Codex

enum CodexQuotaReader {
    /// Reads the newest `token_count` record out of the most recently touched Codex threads.
    ///
    /// Walks the threads newest-first and stops at the first one that yields a reading, rather
    /// than scanning all of them: the allowance is per account, not per thread, so the newest
    /// observation is the only one that isn't already superseded. The loop exists only because
    /// a thread can end without a `token_count` — a fresh one that never completed a turn.
    ///
    /// Cross-checked against `codex app-server`'s `account/rateLimits/read`, which is the live
    /// query and the obvious alternative: 53.0% here against 52% there, taken minutes apart. The
    /// disk stays the source because it costs 16ms and no subprocess, against 0.64s for spawning
    /// a server to be told the same thing.
    static func read(sessions: [Session], limit: Int = 8) -> [AgentQuota] {
        let candidates = sessions
            .filter { $0.agent == .codex }
            .sorted { $0.lastActivity > $1.lastActivity }
            .prefix(limit)

        for session in candidates {
            let path = session.fileURL.path
            guard !path.isEmpty,
                  let quota = RolloutTailReader.rateLimit(path, observedAt: session.lastActivity)
            else { continue }
            return [quota]
        }
        return []
    }
}

extension RolloutTailReader {
    /// The last `token_count` record's `rate_limits.primary`, if the tail holds one.
    ///
    /// Only `primary` — measured, `secondary` is null in **all 5403** records on this machine, and
    /// `codex app-server` reports a single bucket (`rateLimitsByLimitId` has one key, `codex`).
    /// Codex has one window; Claude has two.
    ///
    /// Separate from `scan` because it answers a different question for a different page, and
    /// the session list must not pay for it — measured 48 Codex threads scanned in 16ms, and
    /// that budget is why the Usage tab reads at most a handful of files instead of all of them.
    static func rateLimit(_ path: String, observedAt: Date) -> AgentQuota? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }

        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }

        var latest: AgentQuota?
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

            latest = AgentQuota(
                agent: .codex,
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
