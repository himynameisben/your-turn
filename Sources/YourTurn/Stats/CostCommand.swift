import Foundation

/// Implementation of `YourTurn --cost`: the verification entry point for the usage pipeline,
/// the same role `--dump` plays for the session pipeline.
///
/// Everything here is deliberately English and column-shaped — these numbers get diffed
/// against `ccusage`, against Claude Code's own OTel `cost_usd`, and against the previous run
/// after a change. Output stability matters more than reading nicely in someone's language.
///
/// `--cost --no-cache` forces a cold scan; without it the second run should be near-instant.
/// `--cost --refresh-prices` exercises the one network call the app makes, which the window
/// otherwise only fires once a day — the only way to see whether it still parses LiteLLM's
/// current shape rather than silently falling back to the bundled snapshot.
enum CostCommand {
    static func run(useCache: Bool = true, refreshPrices: Bool = false) {
        let cache = useCache ? UsageCache() : nil
        var prices = PriceTable.load()
        if refreshPrices {
            let started = Date()
            let refreshed = fetchSynchronously()
            let elapsed = StatsFormat.milliseconds(Date().timeIntervalSince(started))
            if let refreshed {
                let added = refreshed.models.keys.filter { prices.price(for: $0) == nil }
                prices = refreshed
                print("\nprice refresh   \(refreshed.models.count) models in \(elapsed)"
                    + (added.isEmpty ? "" : " · new: \(added.sorted().joined(separator: ", "))"))
            } else {
                print("\nprice refresh   failed after \(elapsed) — keeping \(prices.source == .bundled ? "bundled" : "cached") table")
            }
        }
        let scan = UsageScanner.scan(cache: cache)
        let stats = UsageStats.build(scan, prices: prices)

        print("""

        ── Scan ───────────────────────────────
        files           \(scan.files) (\(scan.filesFromCache) from cache, \
        \(scan.files - scan.filesFromCache) parsed · \(bytes(scan.bytesRead)))
        rows            \(scan.records.count + scan.duplicateRows + scan.crossFileDuplicates) usage rows → \
        \(scan.records.count) unique requests
        deduped         \(scan.duplicateRows) same-file (\(percent(scan.duplicateRows, of: scan.records.count + scan.duplicateRows))) · \
        \(scan.crossFileDuplicates) cross-file
        turns           \(scan.turns.count) turn_duration records
        time            \(ms(scan.duration))
        prices          \(prices.models.count) models · updated \(prices.updated) · \
        \(prices.source == .bundled ? "bundled" : "downloaded")
        """)

        let unknown = stats.unpriced == 0
            ? "none"
            : "\(stats.unpriced) request(s) · \(stats.unpricedModels.joined(separator: ", "))"
        print("""

        ── Cost ───────────────────────────────
        total           \(usd(stats.cost)) over \(stats.byDay.count) day(s)
        tokens          \(tokens(stats.tokens.total)) — \
        in \(tokens(stats.tokens.input)) · out \(tokens(stats.tokens.output)) · \
        cache read \(tokens(stats.tokens.cacheRead)) · cache write \(tokens(stats.tokens.cacheWrite))
        subagents       \(stats.subagentRequests) request(s) · \(tokens(stats.subagentTokens.total)) \
        (\(percent(stats.subagentRequests, of: stats.requests)) of requests)
        no price        \(unknown)
        """)

        print("\n── By model ───────────────────────────")
        for bucket in stats.byModel {
            // A model with no price prints "—", never "$0.00": the two are indistinguishable
            // on screen and mean opposite things.
            print(row(bucket, priced: prices.price(for: bucket.key) != nil))
        }

        print("\n── By project (top 12) ────────────────")
        for bucket in stats.byProject.prefix(12) { print(row(bucket)) }

        print("\n── By day (last 14) ───────────────────")
        for day in stats.byDay.suffix(14) {
            let cost = pad(usd(day.cost), 11, left: false)
            let count = pad(tokens(day.tokens.total), 9, left: false)
            print("  \(day.key)  \(cost)  \(count)  \(day.sessions.count) session(s)")
        }

        let rhythm = stats.rhythm
        print("""

        ── Rhythm ─────────────────────────────
        turns           \(rhythm.turns) · avg \(duration(rhythm.averageTurn ?? 0))
        you waited      \(duration(rhythm.claudeRuntime)) of Claude runtime
        Claude waited   \(duration(rhythm.totalWait)) across \(rhythm.waits.count) gap(s) · \
        median \(duration(rhythm.medianWait ?? 0))
        busiest hour    \(rhythm.busiestHour.map { "\($0):00" } ?? "—")
        """)
        print("  hours " + histogram(rhythm.byHour))
    }

    /// `run()` is a plain synchronous entry point called before any scene exists, so the async
    /// download has to be waited on.
    ///
    /// A semaphore rather than the run-loop pump `--render` uses: that pump exists because
    /// `SessionStore.refresh()` is `@MainActor`, and blocking the main thread would strand its
    /// continuation forever. `PriceTable.refresh()` is nonisolated — it's a URLSession call —
    /// so blocking here is safe, and the signal is also what orders the write to the box.
    private static func fetchSynchronously() -> PriceTable? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box()
        Task {
            box.value = await PriceTable.refresh()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    private final class Box: @unchecked Sendable {
        var value: PriceTable?
    }

    // MARK: - Formatting

    private static func row(_ bucket: UsageStats.Bucket, priced: Bool = true) -> String {
        let cost = pad(priced ? usd(bucket.cost) : "—", 11, left: false)
        let count = pad(tokens(bucket.tokens.total), 9, left: false)
        return "  \(pad(bucket.name, 30)) \(cost)  \(count)  \(bucket.requests) req"
    }

    /// A 24-cell block-height bar, one cell per hour of the local day. Terminal-only, so it
    /// can lean on Unicode blocks the SwiftUI version can't.
    private static func histogram(_ counts: [Int]) -> String {
        guard let peak = counts.max(), peak > 0 else { return "—" }
        let blocks = Array(" ▁▂▃▄▅▆▇█")
        return counts.map { count in
            String(blocks[min(blocks.count - 1, count * (blocks.count - 1) / peak)])
        }.joined()
    }

    // Shared with the stats window through `StatsFormat`, so the two can't drift apart on
    // what "$6,180" or "7.4G" means.
    private static func usd(_ value: Double) -> String { StatsFormat.usd(value) }
    private static func tokens(_ count: Int) -> String { StatsFormat.tokens(count) }
    private static func bytes(_ count: Int) -> String { StatsFormat.bytes(count) }
    private static func duration(_ s: TimeInterval) -> String { StatsFormat.duration(s) }
    private static func ms(_ s: TimeInterval) -> String { StatsFormat.milliseconds(s) }
    private static func percent(_ part: Int, of whole: Int) -> String {
        StatsFormat.percent(part, of: whole)
    }

    /// Same reason as `DumpCommand.pad`: `String(format:)` drops the field width on `%@`.
    private static func pad(_ s: String, _ width: Int, left: Bool = true) -> String {
        guard s.count < width else { return String(s.prefix(width)) }
        let spaces = String(repeating: " ", count: width - s.count)
        return left ? s + spaces : spaces + s
    }
}
