import Foundation

/// The five token buckets that get billed at five different rates.
///
/// Cache reads dominate real transcripts by an order of magnitude (measured: 200-500M tokens
/// a day, almost all of it cache reads), which is why they can't be folded into `input` — at
/// 1/10th the input rate, merging them would inflate the bill roughly tenfold.
struct TokenCounts: Sendable, Codable, Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    /// `cache_creation.ephemeral_5m_input_tokens`
    var cacheWrite5m = 0
    /// `cache_creation.ephemeral_1h_input_tokens` — a different rate from the 5m one
    var cacheWrite1h = 0

    var total: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }
    var cacheWrite: Int { cacheWrite5m + cacheWrite1h }

    static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: a.input + b.input,
            output: a.output + b.output,
            cacheRead: a.cacheRead + b.cacheRead,
            cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m,
            cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h
        )
    }

    static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }
}

/// One entry of `usage.iterations` — or the whole request, when there are none.
///
/// Why a request can't be one flat token count: when `iterations` exists, the top-level
/// `usage` only sums the `type: "message"` entries and **silently drops
/// `advisor_message`** — which routinely ran on a different model. The source research
/// measured one request reporting 1,931 output tokens at the top level while an advisor
/// iteration burned 9,472 output and 133,627 input on `claude-fable-5`: a 92% error on that
/// single request. Only 33 of 36,265 requests here carry an advisor iteration, but they are
/// by far the biggest ones.
struct UsageSegment: Sendable, Codable, Equatable {
    let model: String
    let tokens: TokenCounts
}

/// One billable API request, already deduplicated by `requestId`.
///
/// Deduplication is not optional: measured 73,792 usage rows across `~/.claude/projects`
/// collapsing to 36,471 unique `requestId`s — a 51% duplication rate, because one API request
/// gets written out as several assistant records. Summing the rows would roughly double the bill.
///
/// **Which row wins matters, and not the way the source research claimed.** That document
/// states the rows for one `requestId` are identical, so first or last gives the same answer.
/// Measured here: 6,036 of 36,481 requests (16.5%) have `output_tokens` *growing* across their
/// rows — the rows are progressive snapshots of a streaming response (one measured request goes
/// 2 → 14,812). `input`/`cache_read`/`cache_creation` are fixed at request start and really are
/// identical, which is why only output drifts. Keeping the first row undercounts output by
/// 15% on `claude-opus-5` and **67% on `claude-sonnet-5`**; keeping the largest matches
/// ccusage to +0.0% on every model. Hence: on collision, the row with more output wins.
struct UsageRecord: Sendable, Codable, Equatable {
    let requestId: String
    let timestamp: Date
    let sessionId: String
    let projectPath: String
    /// Came from `<uuid>/subagents/agent-*.jsonl` rather than the session transcript itself.
    /// Measured at 10,183 requests / 1.54G tokens — about a quarter of everything.
    let isSubagent: Bool
    let segments: [UsageSegment]

    /// The model to attribute the request to in listings — the request's own, not each
    /// iteration's. Pricing always walks `segments` instead.
    var model: String { segments.first?.model ?? "" }

    var tokens: TokenCounts {
        segments.reduce(into: TokenCounts()) { $0 += $1.tokens }
    }
}

/// A `system/turn_duration` record: how long one Claude turn actually ran.
///
/// `messageCount` is deliberately not carried over — measured average 489.6 per turn against
/// 1,581 turns, which can't be "messages in this turn" (more likely a running session total).
/// Showing a number nobody has pinned down is worse than showing nothing.
struct TurnRecord: Sendable, Codable, Equatable {
    let sessionId: String
    let timestamp: Date
    let duration: TimeInterval
    let projectPath: String
}

/// Everything one JSONL file contributed. This is also the unit the on-disk cache stores,
/// so it has to be self-contained.
struct FileUsage: Sendable, Codable, Equatable {
    var records: [UsageRecord] = []
    var turns: [TurnRecord] = []
    /// Rows dropped as same-`requestId` duplicates within this file. Reported by `--cost`
    /// so the 48% figure above stays verifiable rather than folklore.
    var duplicateRows = 0
}
