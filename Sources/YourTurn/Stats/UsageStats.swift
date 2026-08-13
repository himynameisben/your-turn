import Foundation

/// Rolls scanned records up into the numbers the stats window and `--cost` both print.
///
/// Aggregation happens once over the whole history; every window the UI offers (today, this
/// week, this month) is then a slice of `byDay` rather than another pass over 36,000 records.
enum UsageStats {
    struct Bucket: Sendable, Identifiable, Equatable {
        /// The identity. For models it's the model string; for projects it's the repository
        /// path, because two different repos can both end in `backend`.
        let key: String
        /// What gets shown — the folder name for projects, the same string for models.
        var name: String
        var cost: Double = 0
        var tokens = TokenCounts()
        var requests = 0
        var id: String { key }
    }

    struct DayBucket: Sendable, Identifiable, Equatable {
        /// Start of the local day. Local, not UTC: "what did I spend today" means the day the
        /// user lived through, not the one the timestamps were written in.
        let date: Date
        let key: String
        var cost: Double = 0
        var tokens = TokenCounts()
        var requests = 0
        var sessions: Set<String> = []
        var id: String { key }
    }

    /// How the day actually went, as opposed to what it cost.
    struct Rhythm: Sendable, Equatable {
        var turns = 0
        /// Summed `turn_duration` — time you spent waiting on Claude.
        var claudeRuntime: TimeInterval = 0
        /// Gaps between a turn ending and the next request in that session — time Claude
        /// spent waiting on you. The name of the app, quantified.
        var waits: [TimeInterval] = []
        /// Requests per hour of the local day, 24 buckets.
        var byHour = [Int](repeating: 0, count: 24)

        var averageTurn: TimeInterval? { turns > 0 ? claudeRuntime / Double(turns) : nil }
        var totalWait: TimeInterval { waits.reduce(0, +) }
        var medianWait: TimeInterval? {
            guard !waits.isEmpty else { return nil }
            return waits.sorted()[waits.count / 2]
        }
        var busiestHour: Int? {
            guard let peak = byHour.max(), peak > 0 else { return nil }
            return byHour.firstIndex(of: peak)
        }
    }

    struct Summary: Sendable {
        var cost: Double = 0
        /// The same total, split by which token bucket it was spent on.
        var costSplit = CostSplit()
        var tokens = TokenCounts()
        var requests = 0
        /// Requests whose model has no entry in the price table. Surfaced rather than
        /// absorbed — an accounting tool that quietly prices unknown tokens at zero is worse
        /// than one that admits it doesn't know.
        var unpriced = 0
        var unpricedModels: [String] = []
        var subagentRequests = 0
        var subagentTokens = TokenCounts()
        var byDay: [DayBucket] = []
        var byModel: [Bucket] = []
        var byProject: [Bucket] = []
        var rhythm = Rhythm()
        var firstDay: Date?
        var lastDay: Date?

        /// Totals over the days on or after `date`, for the today / this week / this month tiles.
        func total(since date: Date) -> (cost: Double, tokens: TokenCounts, requests: Int) {
            byDay.reduce(into: (0.0, TokenCounts(), 0)) { running, day in
                guard day.date >= date else { return }
                running.0 += day.cost
                running.1 += day.tokens
                running.2 += day.requests
            }
        }

        /// The heatmap's grid: `count` whole weeks, ending with the week that contains `end`,
        /// each column running from the locale's first weekday.
        ///
        /// Always the same number of columns, whether you have two months of history or two
        /// years — a grid that grows with the data would resize the whole row every Monday.
        /// Days before you ever ran Claude Code really did cost nothing, so drawing them as
        /// empty cells is accurate, not padding.
        func weeks(_ count: Int, endingAt end: Date, calendar: Calendar = .current) -> [[DayBucket]] {
            guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: end),
                  let start = calendar.date(byAdding: .day, value: -7 * (count - 1), to: thisWeek.start)
            else { return [] }
            let days = days(from: start, count: count * 7, calendar: calendar)
            return stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        }

        /// The single day that cost the most, over whatever range this summary covers.
        var busiestDay: DayBucket? { byDay.max { $0.tokens.total < $1.tokens.total } }


        private func days(from start: Date, count: Int, calendar: Calendar) -> [DayBucket] {
            let byDate = Dictionary(byDay.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
            let first = calendar.startOfDay(for: start)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return (0..<count).compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: offset, to: first) else { return nil }
                return byDate[date] ?? DayBucket(date: date, key: formatter.string(from: date))
            }
        }
    }

    /// `range` scopes every number on the page to one month or one week. Applied here rather
    /// than by filtering `byDay` afterwards, because `byProject` / `byModel` / `rhythm` can't
    /// be reconstructed from daily totals — a month's project ranking is a different question
    /// from the sum of its days.
    ///
    /// Rebuilding costs one pass over the scanned records and no disk access, so switching
    /// months stays interactive.
    static func build(
        _ scan: UsageScanner.Result,
        prices: PriceTable,
        range: Range<Date>? = nil,
        calendar: Calendar = .current
    ) -> Summary {
        var summary = Summary()
        var days: [Date: DayBucket] = [:]
        var models: [String: Bucket] = [:]
        var projects: [String: Bucket] = [:]
        var projectRoots: [String: String] = [:]
        var unpricedModels = Set<String>()

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        let records = range.map { window in
            scan.records.filter { window.contains($0.timestamp) }
        } ?? scan.records
        let turns = range.map { window in
            scan.turns.filter { window.contains($0.timestamp) }
        } ?? scan.turns

        for record in records {
            let tokens = record.tokens
            let split = Pricing.split(record, prices: prices)
            if split == nil {
                summary.unpriced += 1
                for segment in record.segments where prices.price(for: segment.model) == nil {
                    unpricedModels.insert(segment.model)
                }
            }
            let dollars = split?.total ?? 0

            summary.costSplit += split ?? CostSplit()
            summary.cost += dollars
            summary.tokens += tokens
            summary.requests += 1
            if record.isSubagent {
                summary.subagentRequests += 1
                summary.subagentTokens += tokens
            }

            let day = calendar.startOfDay(for: record.timestamp)
            var bucket = days[day] ?? DayBucket(date: day, key: dayFormatter.string(from: day))
            bucket.cost += dollars
            bucket.tokens += tokens
            bucket.requests += 1
            bucket.sessions.insert(record.sessionId)
            days[day] = bucket

            // Per segment, not per record: when an advisor iteration ran on a different
            // model, that model is exactly what this breakdown exists to reveal. `requests`
            // still counts each record once per model so the column stays a request count.
            var counted = Set<String>()
            for segment in record.segments {
                let segmentCost = prices.price(for: segment.model)
                    .map { Pricing.cost(segment.tokens, $0) } ?? 0
                add(&models, key: segment.model, name: segment.model,
                    cost: segmentCost, tokens: segment.tokens,
                    countRequest: counted.insert(segment.model).inserted)
            }
            let root = ProjectRoot.resolve(record.projectPath, cache: &projectRoots)
            add(&projects, key: root, name: ProjectRoot.name(of: root),
                cost: dollars, tokens: tokens)

            let hour = calendar.component(.hour, from: record.timestamp)
            if hour >= 0, hour < 24 { summary.rhythm.byHour[hour] += 1 }
        }

        summary.byDay = days.values.sorted { $0.date < $1.date }
        summary.byModel = models.values.sorted { $0.cost > $1.cost }
        summary.byProject = projects.values.sorted { $0.cost > $1.cost }
        summary.unpricedModels = unpricedModels.sorted()
        summary.firstDay = summary.byDay.first?.date
        summary.lastDay = summary.byDay.last?.date

        summary.rhythm.turns = turns.count
        summary.rhythm.claudeRuntime = turns.reduce(0) { $0 + $1.duration }
        // Gaps are measured against the in-range requests only, so a turn at the very end of
        // a month doesn't reach into the next one for its answer.
        summary.rhythm.waits = waits(records: records, turns: turns)
        return summary
    }

    // MARK: -

    /// How long Claude sat waiting for you: from a turn ending to the next request in the
    /// same session.
    ///
    /// Deliberately derived from `turn_duration` records and request timestamps only — no
    /// user message is read. "This app doesn't parse your conversations" has to keep being
    /// true for the stats window too.
    ///
    /// Gaps over 6 hours are dropped: past that you didn't leave Claude waiting, you went to
    /// bed. Measured on real data, the cap keeps 1,291 samples with a 336s median.
    static func waits(records: [UsageRecord], turns: [TurnRecord]) -> [TimeInterval] {
        guard !turns.isEmpty else { return [] }
        var bySession: [String: [Date]] = [:]
        for record in records {
            bySession[record.sessionId, default: []].append(record.timestamp)
        }
        // `records` arrives sorted by timestamp, so each session's slice is already ordered.

        var result: [TimeInterval] = []
        for turn in turns {
            guard let stamps = bySession[turn.sessionId],
                  let next = firstStamp(in: stamps, after: turn.timestamp)
            else { continue }
            let gap = next.timeIntervalSince(turn.timestamp)
            if gap > 0, gap < 6 * 3600 { result.append(gap) }
        }
        return result
    }

    private static func firstStamp(in stamps: [Date], after date: Date) -> Date? {
        var low = 0, high = stamps.count
        while low < high {
            let mid = (low + high) / 2
            if stamps[mid] <= date { low = mid + 1 } else { high = mid }
        }
        return low < stamps.count ? stamps[low] : nil
    }

    private static func add(
        _ buckets: inout [String: Bucket], key: String, name: String,
        cost: Double, tokens: TokenCounts, countRequest: Bool = true
    ) {
        var bucket = buckets[key] ?? Bucket(key: key, name: name)
        bucket.cost += cost
        bucket.tokens += tokens
        if countRequest { bucket.requests += 1 }
        buckets[key] = bucket
    }
}
