import Foundation
import Observation

/// The usage tab's single source of truth, and the reason its scan can afford to be
/// expensive: it runs when you switch to that tab, not on the 30-second timer `SessionStore`
/// uses.
///
/// Measured on a 1.0GB `~/.claude/projects`: 1.5s cold, 36ms once `UsageCache` is warm.
@Observable
@MainActor
final class StatsStore {
    /// Scoped to `period`. Everything on the page except the heatmap reads this.
    private(set) var summary: UsageStats.Summary?
    /// Unscoped. The heatmap draws all of history regardless of the filter, because it's also
    /// the control you use to move the filter around — dimming the unselected weeks is the
    /// point, and you can't dim what isn't drawn.
    private(set) var overall: UsageStats.Summary?
    private(set) var prices = PriceTable.load()
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    /// Empty for anyone running neither the status-line bridge nor Codex, which is the only
    /// reason the page can decide whether to draw that section at all. Claude's two windows
    /// come first because the five-hour one is the one that stops you today.
    private(set) var quotas: [AgentQuota] = []

    var period = UsagePeriod.all {
        didSet {
            guard period != oldValue else { return }
            rescope()
        }
    }

    /// Held rather than created per scan: it carries the parsed contents of every file, which
    /// is exactly what makes the second scan cost 36ms instead of 1.5s.
    private let cache = UsageCache()
    /// The scan itself is kept so changing months re-aggregates in memory instead of going
    /// back to disk.
    private var scan: UsageScanner.Result?
    private var rescoping: Task<Void, Never>?

    func load() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let prices = prices
        let result = await Task.detached(priority: .userInitiated) { [cache] in
            UsageScanner.scan(cache: cache)
        }.value
        scan = result
        // Neither reader shares anything with the scan above: Claude's allowance is one small
        // file the status-line bridge leaves behind, and Codex's is its own index query plus a
        // handful of tail reads. Different questions, different disks.
        quotas = await Task.detached(priority: .userInitiated) {
            ClaudeQuotaReader.read() + CodexQuotaReader.read(sessions: CodexScanner.scan())
        }.value
        overall = await aggregate(result, prices: prices, range: nil)
        summary = period.mode == .all
            ? overall
            : await aggregate(result, prices: prices, range: period.range())
        lastScan = Date()
    }

    /// What the usage tab calls when you switch to it.
    ///
    /// Switching tabs must not feel like it costs anything. A warm rescan is only 36ms, but
    /// flipping back and forth would still spend it for nothing — so anything scanned within
    /// the last minute is simply reused, and the 30-second session timer never touches this
    /// at all.
    func loadIfNeeded(staleAfter: TimeInterval = 60) async {
        if summary != nil, let lastScan, Date().timeIntervalSince(lastScan) < staleAfter { return }
        await loadAndRefreshPrices()
    }

    /// Opens with whatever prices are already on hand, then quietly improves them.
    ///
    /// Ordered this way on purpose: the page must show numbers immediately, and a price
    /// table that's a few days old moves the total by cents. Re-running `load()` after a
    /// successful download costs another 36ms against the warm cache.
    func loadAndRefreshPrices() async {
        await load()
        guard PriceTable.cacheIsStale, let updated = await PriceTable.refresh() else { return }
        prices = updated
        await load()
    }

    /// Re-aggregates for the newly picked month or week.
    ///
    /// Off the main actor and cancelling its predecessor: holding an arrow down steps through
    /// months faster than a 37,000-record pass completes, and every intermediate month's
    /// result is already stale by the time it lands.
    private func rescope() {
        guard let scan else { return }
        if period.mode == .all, let overall {
            rescoping?.cancel()
            summary = overall
            return
        }
        let prices = prices
        let range = period.range()
        rescoping?.cancel()
        rescoping = Task { [weak self] in
            let scoped = await Self.aggregate(scan, prices: prices, range: range)
            guard !Task.isCancelled else { return }
            self?.summary = scoped
        }
    }

    private func aggregate(
        _ scan: UsageScanner.Result, prices: PriceTable, range: Range<Date>?
    ) async -> UsageStats.Summary {
        await Self.aggregate(scan, prices: prices, range: range)
    }

    private static func aggregate(
        _ scan: UsageScanner.Result, prices: PriceTable, range: Range<Date>?
    ) async -> UsageStats.Summary {
        await Task.detached(priority: .userInitiated) {
            UsageStats.build(scan, prices: prices, range: range)
        }.value
    }

    /// Demo/preview only (`--render … --demo`). A real scan would put this machine's project
    /// names and actual spend into a published screenshot.
    ///
    /// Takes a scan rather than a finished summary, and aggregates it here and now: that runs
    /// the demo through the real pricing, the real aggregation and the real period filter, so
    /// the screenshot stays evidence that those work. Synchronous because `ImageRenderer`
    /// won't wait for a Task — set `period` before calling this, not after.
    func loadDemo(_ scan: UsageScanner.Result, quotas: [AgentQuota] = []) {
        self.scan = scan
        overall = UsageStats.build(scan, prices: prices, range: nil)
        summary = period.mode == .all
            ? overall
            : UsageStats.build(scan, prices: prices, range: period.range())
        self.quotas = quotas
        lastScan = Date()
    }
}

extension PriceTable {
    /// Refresh at most daily. Model prices change on the order of months, and the download is
    /// 1.6MB — checking on every tab switch would be all cost and no accuracy.
    static var cacheIsStale: Bool {
        guard let modified = (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        else { return true }
        return Date().timeIntervalSince(modified) > 86_400
    }
}
