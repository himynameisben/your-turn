import SwiftUI

/// The usage page: what these sessions cost, and how the days actually went.
///
/// A page inside the main window, not a window of its own. The scan behind it is heavy
/// (1.5s cold) but that's handled by *when* it runs — `MainWindowPage` fires it on arrival
/// and `StatsStore.loadIfNeeded` skips repeats, so it never rides the window's 30-second
/// session timer. What it must not become is the front page: the inbox is the product, and
/// a spend dashboard promoted to the default view would turn Your Turn into the monitor it
/// was written not to be. Hence a tab you choose, defaulting elsewhere.
///
/// Everything here is plain SwiftUI — no AppKit-backed control needs an offscreen stand-in,
/// and no `LazyVStack` appears, so `--render` can rasterize the whole page.
struct UsageSections: View {
    let store: StatsStore
    let now: Date

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let summary = store.summary, summary.requests > 0 {
                sections(summary)
            } else if store.overall != nil {
                // The period row stays up even with nothing to show: a filter you can't see
                // is a filter you can't undo, and stepping into a quiet week is the most
                // ordinary way to land here.
                StatsRow(label: L("Period")) { PeriodPicker(store: store, now: now) }
                divider
                empty
            } else {
                empty
            }
        }
    }

    /// Three different nothings, and telling them apart is the whole job of this view: still
    /// working, never used Claude Code at all, and stepped into a quiet week. Answering the
    /// first-run case with "nothing in this period" would send a new user hunting for a
    /// filter they never set.
    private var empty: some View {
        Text(message)
            .font(Theme.lede)
            .foregroundStyle(theme.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 90)
    }

    private var message: String {
        guard let overall = store.overall, !store.isScanning else { return L("Reading your transcripts…") }
        return overall.requests == 0 ? L("No usage recorded yet") : L("Nothing recorded in this period.")
    }

    @ViewBuilder
    private func sections(_ summary: UsageStats.Summary) -> some View {
        StatsRow(label: L("Period")) { PeriodPicker(store: store, now: now) }
        divider
        // The label follows what the tiles became: "Recently" describes today/this week/this
        // month, and describes nothing at all once you're looking at March.
        StatsRow(label: store.period.mode == .all ? L("Recently") : L("Totals")) {
            RecentTiles(summary: summary, period: store.period, now: now)
        }
        divider
        // Draws `overall`, never `summary` — the grid is the filter's control surface, so it
        // has to keep showing the weeks you aren't looking at.
        StatsRow(label: L("Each day")) {
            Heatmap(summary: store.overall ?? summary, store: store, now: now)
        }
        divider
        StatsRow(label: L("Projects")) {
            RankedBars(buckets: Array(summary.byProject.prefix(8)))
        }
        divider
        StatsRow(label: L("Models")) {
            RankedBars(
                buckets: summary.byModel.filter { $0.cost > 0 },
                subagentShare: summary.subagentRequests > 0
                    ? StatsFormat.percent(summary.subagentRequests, of: summary.requests) : nil
            )
        }
        divider
        StatsRow(label: L("Where it goes")) { CostBreakdown(summary: summary) }
        divider
        StatsRow(label: L("Rhythm")) { RhythmBlock(rhythm: summary.rhythm) }
        // Last of the data rows, and only for people who run Codex. It sits apart from
        // everything above because it is a different kind of fact: every other row on this page
        // is money reconstructed from tokens, and this one is an allowance on a clock. Putting
        // a percentage inside the cost breakdown would invite reading it as a share of spend.
        if let quota = store.codexQuota {
            divider
            StatsRow(label: L("Codex allowance")) { CodexQuotaBlock(quota: quota, now: now) }
        }
        divider
        StatsRow(label: nil) { Provenance(store: store, summary: summary) }
    }

    private var divider: some View {
        Rectangle().fill(theme.rule).frame(height: 1)
    }
}

// MARK: - Masthead text

/// The two lines the main window's masthead shows while the usage page is up.
///
/// Plain functions rather than a view: the masthead itself belongs to `MainWindowPage` — one
/// nameplate for all three pages is the whole point of making this a tab — and only its
/// wording changes with the page.
enum UsageMasthead {
    /// "USAGE · JUN 22 – AUG 13", or the selected period's own name once one is picked.
    /// Falls back to the bare word while the first scan runs, so the header doesn't jump
    /// around once numbers arrive.
    static func dateline(_ summary: UsageStats.Summary?, period: UsagePeriod) -> String {
        guard period.mode == .all else { return "\(L("USAGE")) · \(period.label())" }
        guard let summary, let first = summary.firstDay, let last = summary.lastDay
        else { return L("USAGE") }
        let f = DateFormatter()
        f.locale = Localization.locale
        f.dateFormat = L("stats.range.format")
        return "\(L("USAGE")) · \(f.string(from: first)) – \(f.string(from: last))"
    }

    /// The headline answers the filter, not the archive: with a month selected, "across 36
    /// projects" would be quoting a number the page below no longer shows.
    static func headline(_ summary: UsageStats.Summary?, period: UsagePeriod) -> String {
        guard let summary else { return L("Adding it up…") }
        let amount = StatsFormat.usd(summary.cost)
        guard summary.requests > 0 else {
            return period.mode == .all ? L("Adding it up…") : L("Nothing recorded in this period.")
        }
        let projects = summary.byProject.count
        return projects == 1
            ? L("\(amount) across \(projects) project.")
            : L("\(amount) across \(projects) projects.")
    }
}

// MARK: - Page skeleton

/// Right-aligned label in the gutter, content on the right — the same spine as the main
/// window's rows, so the two windows read as pages of one publication.
private struct StatsRow<Content: View>: View {
    let label: String?
    @ViewBuilder let content: Content

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label ?? "")
                .font(Theme.projectName)
                .foregroundStyle(theme.muted)
                .lineLimit(1)
                .frame(width: Theme.gutter, alignment: .trailing)
                .padding(.trailing, 22)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, Theme.pageInset)
        }
        .padding(.vertical, 20)
    }
}

// MARK: - Period picker

/// All time / a month / a week, plus arrows to walk backwards through them.
///
/// A stepper rather than a dropdown of every month you've ever used Claude Code: the months
/// you actually want are almost always this one and the one before it, and an arrow gets
/// there in one click without opening anything.
private struct PeriodPicker: View {
    let store: StatsStore
    let now: Date

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            PillPicker(options: UsagePeriod.Mode.allCases, selection: modeBinding) { $0.displayName }

            if store.period.mode != .all {
                HStack(spacing: 4) {
                    arrow("chevron.left", delta: -1, enabled: true)
                    Text(store.period.label(now: now))
                        .font(Theme.meta)
                        .foregroundStyle(theme.text)
                        // Fixed width so stepping between "Aug 3 – 9" and "Aug 31 – Sep 6"
                        // doesn't shuffle the arrows out from under the cursor.
                        .frame(width: 128)
                    // Forward stops at the present: there's nothing after today to show, and
                    // an arrow that scrolls into empty months just looks broken.
                    arrow("chevron.right", delta: 1, enabled: !store.period.isAtPresent(now: now))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var modeBinding: Binding<UsagePeriod.Mode> {
        Binding(
            get: { store.period.mode },
            // Jumps to the period containing today rather than keeping the old anchor: coming
            // back from "March, week 2" into month mode should land on this month, not March.
            set: { store.period = UsagePeriod(mode: $0, anchor: now) }
        )
    }

    private func arrow(_ symbol: String, delta: Int, enabled: Bool) -> some View {
        Button {
            store.period = store.period.stepped(by: delta)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(enabled ? theme.muted : theme.rule)
                .frame(width: 20, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Recent totals

/// The three numbers at the top.
///
/// They change meaning with the filter, which is the point: with no filter the useful
/// question is "how am I doing right now" (today / this week / this month), but once you've
/// picked March the answer to "this month" is irrelevant — what you want is the shape of
/// March itself.
/// Codex's allowance: one number and one clock.
///
/// A bar rather than another `Theme.display` figure, because it is the one quantity on this
/// page with a ceiling — every dollar total above it can always go up, and a percentage cannot.
/// Drawing it in the same typeface as spend would say they're the same kind of number.
private struct CodexQuotaBlock: View {
    let quota: CodexQuota
    let now: Date

    @Environment(\.theme) private var theme

    private var fraction: Double { min(max(quota.usedPercent / 100, 0), 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(StatsFormat.percentUsed(quota.usedPercent))
                    .font(Theme.display)
                    .foregroundStyle(theme.text)
                Text(L("of your \(quota.windowLabel) allowance"))
                    .font(Theme.meta)
                    .foregroundStyle(theme.muted)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.rule)
                    Capsule()
                        .fill(theme.waitingChip.fg)
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
            .frame(maxWidth: 320)
            Text(footnote)
                .font(Theme.meta)
                .foregroundStyle(theme.faint)
        }
    }

    /// Says when it was measured as well as when it resets. The reading is lifted from the last
    /// turn of your most recent thread, so a week away from Codex leaves a week-old number —
    /// and a stale percentage presented as current is the one way this row could mislead.
    private var footnote: String {
        let reset = quota.resetsAt.map {
            L("Resets \(RelativeTime.until($0, from: now))")
        }
        let measured = L("measured \(RelativeTime.format(quota.observedAt, from: now))")
        return [reset, measured].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct RecentTiles: View {
    let summary: UsageStats.Summary
    let period: UsagePeriod
    let now: Date

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 34) {
            if period.mode == .all {
                tile(L("Today"), summary.total(since: Calendar.current.startOfDay(for: now)))
                tile(L("This week"), summary.total(since: startOf(.weekOfYear)))
                tile(L("This month"), summary.total(since: startOf(.month)))
            } else {
                tile(L("Total"), (summary.cost, summary.tokens, summary.requests))
                tile(L("Per active day"), average)
                busiest
            }
            Spacer(minLength: 0)
        }
    }

    private func startOf(_ component: Calendar.Component) -> Date {
        Calendar.current.dateInterval(of: component, for: now)?.start
            ?? Calendar.current.startOfDay(for: now)
    }

    /// Averaged over the days you actually worked, not over the calendar. Dividing a week's
    /// spend by 7 when you only opened the laptop twice describes nobody's day.
    private var average: (Double, TokenCounts, Int) {
        let days = max(summary.byDay.count { $0.requests > 0 }, 1)
        var tokens = summary.tokens
        tokens.input /= days
        tokens.output /= days
        tokens.cacheRead /= days
        tokens.cacheWrite5m /= days
        tokens.cacheWrite1h /= days
        return (summary.cost / Double(days), tokens, summary.requests / days)
    }

    @ViewBuilder
    private var busiest: some View {
        if let day = summary.busiestDay {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Busiest day"))
                    .font(Theme.meta)
                    .foregroundStyle(theme.faint)
                Text(StatsFormat.usd(day.cost))
                    .font(Theme.display)
                    .foregroundStyle(theme.text)
                Text(dayLabel(day.date))
                    .font(Theme.meta)
                    .foregroundStyle(theme.muted)
            }
        }
    }

    private func tile(_ title: String, _ total: (cost: Double, tokens: TokenCounts, requests: Int)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.meta)
                .foregroundStyle(theme.faint)
            Text(StatsFormat.usd(total.cost))
                .font(Theme.display)
                .foregroundStyle(theme.text)
            Text(L("\(StatsFormat.tokens(total.tokens.total)) tokens · \(total.requests) requests"))
                .font(Theme.meta)
                .foregroundStyle(theme.muted)
        }
    }

    private func dayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Localization.locale
        f.dateFormat = L("stats.range.format")
        return f.string(from: date)
    }
}

// MARK: - Heatmap

/// A contribution-graph grid, keyed on tokens rather than commits: one square per day, weeks
/// as columns, weekdays as rows.
///
/// Tokens and not dollars on purpose. The squares encode *effort* — how hard you leaned on
/// Claude that day — and tokens are the honest measure of that; pricing them would make the
/// same amount of work change shade whenever a model's rate does, or whenever you switch
/// from Opus to Haiku. The dollar figures live everywhere else on the page.
///
/// It also doubles as the filter's control surface: clicking a square selects the month or
/// week it belongs to, and unselected weeks fade. That's why it draws `overall` and ignores
/// the current scope — a navigator that only shows where you already are can't navigate.
private struct Heatmap: View {
    let summary: UsageStats.Summary
    let store: StatsStore
    let now: Date

    @Environment(\.theme) private var theme

    /// Half a year. A full 53-week year is the GitHub convention but needs ~740pt of width,
    /// and this window can be as narrow as 720pt with a 168pt gutter taken out of it.
    private static let weekCount = 26
    /// 14 + 3 × 26 columns = 442pt, plus a 32pt weekday gutter. The narrowest this window
    /// gets is 720pt, which leaves 492pt of content once the page gutter and insets are out —
    /// so the grid fills the row at minimum width without ever needing to scroll sideways.
    private static let cell: CGFloat = 14
    private static let gap: CGFloat = 3
    private static var column: CGFloat { cell + gap }

    var body: some View {
        let weeks = summary.weeks(Self.weekCount, endingAt: now)
        let thresholds = Self.thresholds(weeks.flatMap { $0 })

        VStack(alignment: .leading, spacing: 6) {
            monthLabels(weeks)
            HStack(alignment: .top, spacing: 6) {
                weekdayLabels
                HStack(alignment: .top, spacing: Self.gap) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: Self.gap) {
                            ForEach(week) { day in cell(day, thresholds) }
                        }
                    }
                }
            }
            legend
        }
    }

    // MARK: Cells

    private func cell(_ day: UsageStats.DayBucket, _ thresholds: [Int]) -> some View {
        let level = Self.level(day.tokens.total, thresholds)
        let selected = store.period.contains(day.date)
        return RoundedRectangle(cornerRadius: 2.5)
            .fill(color(level))
            // Everything outside the selection stays legible but recedes, so the grid reads
            // as "you are here" instead of hiding the context you're navigating by.
            .opacity(selected ? 1 : 0.28)
            .frame(width: Self.cell, height: Self.cell)
            .contentShape(.rect)
            .onTapGesture { select(day.date) }
            .help(tooltip(day))
    }

    /// Clicking narrows to the period that square belongs to. From "all time" it drops you
    /// into that week, which is the finer of the two and the one a single square implies.
    private func select(_ date: Date) {
        let mode: UsagePeriod.Mode = store.period.mode == .month ? .month : .week
        store.period = UsagePeriod(mode: mode, anchor: date)
    }

    private func color(_ level: Int) -> Color {
        switch level {
        case 0: theme.rule
        case 1: theme.text.opacity(0.22)
        case 2: theme.text.opacity(0.42)
        case 3: theme.text.opacity(0.66)
        default: theme.text.opacity(0.92)
        }
    }

    private func tooltip(_ day: UsageStats.DayBucket) -> String {
        let date = dayLabel(day.date)
        guard day.requests > 0 else { return L("\(date) · nothing") }
        return L("\(date) · \(StatsFormat.tokens(day.tokens.total)) tokens · \(StatsFormat.usd(day.cost))")
    }

    // MARK: Chrome

    /// Month names sit above the column their month starts in, drawn as offsets rather than
    /// as an `HStack` of 16pt slots — "August" is four columns wide and would be truncated
    /// into "Au…" by any layout that made it fit its own cell.
    private func monthLabels(_ weeks: [[UsageStats.DayBucket]]) -> some View {
        let calendar = Calendar.current
        let starts: [(Int, String)] = weeks.enumerated().compactMap { index, week in
            guard let first = week.first else { return nil }
            // Label a column when its month differs from the previous column's, and skip the
            // very first one — its month started off-screen, so the name would be a lie.
            guard index > 0, let previous = weeks[index - 1].first,
                  !calendar.isDate(first.date, equalTo: previous.date, toGranularity: .month)
            else { return nil }
            return (index, monthLabel(first.date))
        }
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(height: 13)
            ForEach(starts, id: \.0) { index, name in
                Text(name)
                    .font(Theme.meta)
                    .foregroundStyle(theme.faint)
                    .fixedSize()
                    .offset(x: CGFloat(index) * Self.column)
            }
        }
        .padding(.leading, Self.weekdayColumn + 6)
    }

    private static let weekdayColumn: CGFloat = 26

    /// Every other row labelled, the way contribution graphs do it — seven stacked three-letter
    /// labels at 13pt each would be denser than the grid they annotate.
    private var weekdayLabels: some View {
        var calendar = Calendar.current
        // Names follow the UI's resolved language; `firstWeekday` keeps following the user's
        // region, which is a different question — an English UI in Taiwan still starts its
        // week on Sunday.
        calendar.locale = Localization.locale
        let symbols = calendar.shortWeekdaySymbols
        return VStack(spacing: Self.gap) {
            ForEach(0..<7, id: \.self) { row in
                // `firstWeekday` is 1-based and locale-dependent: Sunday-first in the US and
                // Taiwan, Monday-first under ISO. The grid follows whichever the user has.
                let index = (calendar.firstWeekday - 1 + row) % 7
                Text(row % 2 == 1 ? symbols[index] : "")
                    .font(Theme.meta)
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
                    .frame(width: Self.weekdayColumn, height: Self.cell, alignment: .trailing)
            }
        }
    }

    /// What the highlighted squares add up to — the filtered summary when there is one, the
    /// whole grid otherwise.
    private var scoped: UsageStats.Summary { store.summary ?? summary }

    private var legend: some View {
        HStack(spacing: 6) {
            Text(L("Less")).font(Theme.meta).foregroundStyle(theme.faint)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(level))
                    .frame(width: 9, height: 9)
            }
            Text(L("More")).font(Theme.meta).foregroundStyle(theme.faint)
            Spacer(minLength: 12)
            // Counts the highlighted region, not the whole grid: with a month selected, the
            // eye is on those squares, and a caption about the other five months would be
            // answering a question nobody is asking.
            Text(L("\(StatsFormat.tokens(scoped.tokens.total)) tokens over \(scoped.byDay.count) active days"))
                .font(Theme.meta)
                .foregroundStyle(theme.faint)
        }
        .padding(.leading, Self.weekdayColumn + 6)
        .padding(.top, 2)
    }

    private func dayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Localization.locale
        f.dateFormat = L("stats.range.format")
        return f.string(from: date)
    }

    private func monthLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Localization.locale
        f.dateFormat = L("stats.monthLabel.format")
        return f.string(from: date)
    }

    // MARK: Scale

    /// Quartiles of the days you actually used, not equal slices of the range.
    ///
    /// One 500M-token day against a month of 20M ones would, on a linear scale, paint the
    /// whole grid in the palest shade and tell you nothing. Quartiles keep all five shades in
    /// play whatever the spread — the same reason GitHub's graph doesn't scale linearly either.
    static func thresholds(_ days: [UsageStats.DayBucket]) -> [Int] {
        let values = days.map(\.tokens.total).filter { $0 > 0 }.sorted()
        guard values.count >= 4 else { return values.isEmpty ? [0, 0, 0] : [values[0], values[0], values[0]] }
        return [values[values.count / 4], values[values.count / 2], values[values.count * 3 / 4]]
    }

    static func level(_ tokens: Int, _ thresholds: [Int]) -> Int {
        guard tokens > 0 else { return 0 }
        return 1 + thresholds.count { tokens > $0 }
    }
}

// MARK: - Ranked bars

/// Name, proportional bar, amount. Used for both projects and models — same shape, same
/// question: where did it go.
private struct RankedBars: View {
    let buckets: [UsageStats.Bucket]
    var subagentShare: String?

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            let peak = buckets.map(\.cost).max() ?? 0
            ForEach(buckets) { bucket in
                HStack(spacing: 10) {
                    Text(bucket.name)
                        .font(Theme.said)
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 150, alignment: .leading)

                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(theme.text.opacity(0.55))
                            .frame(
                                width: peak > 0 ? max(2, geometry.size.width * bucket.cost / peak) : 0,
                                height: 8
                            )
                            .frame(height: geometry.size.height, alignment: .center)
                    }
                    .frame(height: 14)

                    Text(StatsFormat.usd(bucket.cost))
                        .font(Theme.meta)
                        .foregroundStyle(theme.muted)
                        .frame(width: 62, alignment: .trailing)
                }
            }
            if let subagentShare {
                Text(L("\(subagentShare) of requests came from subagents."))
                    .font(Theme.meta)
                    .foregroundStyle(theme.faint)
                    .padding(.top, 2)
            }
        }
    }
}

// MARK: - Cost breakdown

/// Tokens versus dollars, side by side.
///
/// This is the one number on the page that changes how someone works: measured here, cache
/// reads are 97% of every token that moves but a far smaller share of the bill, while output
/// is a rounding error by volume and a large share of the cost. Showing only token counts —
/// which is what most usage tools do — points at exactly the wrong lever.
private struct CostBreakdown: View {
    let summary: UsageStats.Summary

    @Environment(\.theme) private var theme

    var body: some View {
        let tokens = summary.tokens
        let split = summary.costSplit
        let rows: [(String, Int, Double)] = [
            (L("cache read"), tokens.cacheRead, split.cacheRead),
            (L("cache write"), tokens.cacheWrite, split.cacheWrite),
            (L("output"), tokens.output, split.output),
            (L("input"), tokens.input, split.input),
        ]

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                Text("").frame(width: 96, alignment: .leading)
                heading(L("of tokens"))
                heading(L("of cost"))
                Spacer(minLength: 0)
            }
            .font(Theme.meta)
            .foregroundStyle(theme.faint)

            ForEach(rows, id: \.0) { name, count, cost in
                HStack(spacing: 18) {
                    Text(name)
                        .font(Theme.said)
                        .foregroundStyle(theme.text)
                        .frame(width: 96, alignment: .leading)
                    share(StatsFormat.tokens(count), of: Double(count) / Double(max(tokens.total, 1)))
                    share(StatsFormat.usd(cost), of: cost / max(summary.cost, 0.0001))
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private static let column: CGFloat = 148
    private static let value: CGFloat = 58
    private static let track: CGFloat = 76

    /// Sits over the value, not over the whole column — the bar beside it is a magnitude, and
    /// a heading centred over both would read as labelling the bar.
    private func heading(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text).frame(width: Self.value, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .frame(width: Self.column, alignment: .leading)
    }

    /// Value then bar, both anchored to the same left edge in every row — the two columns only
    /// mean anything if their bars can be read against each other, and a right-aligned bar
    /// starts at a different x on every row.
    private func share(_ text: String, of fraction: Double) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(Theme.meta)
                .foregroundStyle(theme.muted)
                .frame(width: Self.value, alignment: .trailing)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(theme.text.opacity(0.45))
                .frame(width: max(1, Self.track * min(max(fraction, 0), 1)), height: 5)
                .frame(width: Self.track, alignment: .leading)
        }
        .frame(width: Self.column, alignment: .leading)
    }
}

// MARK: - Rhythm

/// The half of the story that isn't money: who spent the day waiting on whom.
private struct RhythmBlock: View {
    let rhythm: UsageStats.Rhythm

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 34) {
                stat(L("You waited"), StatsFormat.duration(rhythm.claudeRuntime),
                     L("across \(rhythm.turns) turns"))
                stat(L("Claude waited"), StatsFormat.duration(rhythm.totalWait),
                     L("typically \(StatsFormat.duration(rhythm.medianWait ?? 0)) at a time"))
                stat(L("A turn takes"), StatsFormat.duration(rhythm.averageTurn ?? 0), nil)
                Spacer(minLength: 0)
            }
            hours
        }
    }

    private func stat(_ title: String, _ value: String, _ note: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.meta)
                .foregroundStyle(theme.faint)
            Text(value)
                .font(Theme.display)
                .foregroundStyle(theme.text)
            if let note {
                Text(note)
                    .font(Theme.meta)
                    .foregroundStyle(theme.muted)
            }
        }
    }

    /// 24 bars, one per hour of your local day.
    private var hours: some View {
        let peak = rhythm.byHour.max() ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    let count = rhythm.byHour[hour]
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(count > 0 ? theme.text.opacity(0.55) : theme.rule)
                        .frame(height: peak > 0 ? max(count > 0 ? 2 : 1, 34 * Double(count) / Double(peak)) : 1)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 34, alignment: .bottom)
            HStack(spacing: 0) {
                Text("00")
                Spacer(minLength: 0)
                Text(L("busiest at \(rhythm.busiestHour ?? 0):00"))
                Spacer(minLength: 0)
                Text("23")
            }
            .font(Theme.meta)
            .foregroundStyle(theme.faint)
        }
    }
}

// MARK: - Provenance

/// Where the numbers came from, and what they aren't.
///
/// Not a footnote for legal comfort — an estimate that doesn't say it's an estimate is the
/// failure mode this whole feature has to avoid. Anything the price table couldn't cover is
/// named here rather than quietly folded in at zero.
private struct Provenance: View {
    let store: StatsStore
    let summary: UsageStats.Summary

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Estimated from your own transcripts against a public price table (\(store.prices.updated)). API-equivalent, not a subscription bill."))
                .font(Theme.meta)
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if summary.unpriced > 0 {
                Text(L("\(summary.unpriced) requests ran on a model with no public price (\(summary.unpricedModels.joined(separator: ", "))) and are left out of the total."))
                    .font(Theme.meta)
                    .foregroundStyle(theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
