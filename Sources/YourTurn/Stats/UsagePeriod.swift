import Foundation

/// What slice of history the usage page is showing.
///
/// Three modes rather than a free date range: the questions people actually ask are "what did
/// this month cost" and "what did last week cost". An arbitrary from/to picker answers those
/// too, but costs two date fields and several taps to do what one arrow does.
struct UsagePeriod: Sendable, Equatable {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case all = "All"
        case month = "Month"
        case week = "Week"

        var id: String { rawValue }

        /// `rawValue` stays English on purpose — it's the `Identifiable` id, so translating it
        /// would move the selection identity with the system language.
        var displayName: String {
            switch self {
            case .all: L("All time")
            case .month: L("Month")
            case .week: L("Week")
            }
        }

        var component: Calendar.Component? {
            switch self {
            case .all: nil
            case .month: .month
            case .week: .weekOfYear
            }
        }
    }

    var mode: Mode = .all
    /// Any instant inside the selected month or week. Ignored when `mode` is `.all`.
    var anchor: Date = Date()

    static let all = UsagePeriod()

    /// nil means "everything" — `UsageStats.build` reads it as no filter at all rather than
    /// as an empty range.
    func range(_ calendar: Calendar = .current) -> Range<Date>? {
        guard let component = mode.component,
              let interval = calendar.dateInterval(of: component, for: anchor)
        else { return nil }
        return interval.start..<interval.end
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard let range = range(calendar) else { return true }
        return range.contains(date)
    }

    /// Moves one month or one week at a time. `.all` has nowhere to step, so it stays put.
    func stepped(by delta: Int, calendar: Calendar = .current) -> UsagePeriod {
        guard let component = mode.component,
              let moved = calendar.date(byAdding: component, value: delta, to: anchor)
        else { return self }
        return UsagePeriod(mode: mode, anchor: moved)
    }

    /// True once stepping forward would land past today — the arrow that would do it is
    /// disabled rather than hidden, so the control doesn't change width as you travel.
    func isAtPresent(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let component = mode.component else { return true }
        return calendar.isDate(anchor, equalTo: now, toGranularity: component)
    }

    /// "August 2026" or "Aug 10 – 16". Both are built from translated patterns rather than
    /// `DateFormatter.dateStyle`, because zh-Hant orders the fields differently.
    func label(now: Date = Date(), calendar: Calendar = .current) -> String {
        switch mode {
        case .all:
            return L("All time")
        case .month:
            return formatted(anchor, L("stats.month.format"))
        case .week:
            guard let range = range(calendar) else { return "" }
            let last = range.upperBound.addingTimeInterval(-1)
            return "\(formatted(range.lowerBound, L("stats.range.format"))) – "
                + "\(formatted(last, L("stats.range.format")))"
        }
    }

    private func formatted(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        // The UI's resolved language, not `Locale.current`: an English UI on a Taiwanese
        // machine must not print "8月" under an English headline.
        f.locale = Localization.locale
        f.dateFormat = pattern
        return f.string(from: date)
    }
}
