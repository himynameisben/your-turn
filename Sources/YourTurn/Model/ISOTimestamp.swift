import Foundation

/// Parses the ISO-8601 timestamps Claude Code writes into its JSONL.
///
/// Hand-rolled fast path instead of going straight to `ISO8601DateFormatter`: a usage scan
/// parses 36,265 timestamps (measured against a 1.0GB `~/.claude/projects`), and the formatter
/// costs roughly 5µs a call — about 180ms of the scan spent on nothing but dates. The formatter
/// stays behind it as the fallback, so anything that isn't the measured
/// `2026-08-11T17:37:31.887Z` shape still parses correctly rather than being dropped.
enum ISOTimestamp {
    static func parse(_ s: String) -> Date? {
        fast(s) ?? isoWithFraction.date(from: s) ?? iso.date(from: s)
    }

    /// Handles exactly `YYYY-MM-DDTHH:MM:SS[.fff]Z`. Anything else — an offset other than Z,
    /// a missing field, a stray character — returns nil and lets the formatter deal with it.
    private static func fast(_ s: String) -> Date? {
        let b = ContiguousArray(s.utf8)
        guard b.count >= 20, b.last == UInt8(ascii: "Z") else { return nil }
        guard b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-"), b[10] == UInt8(ascii: "T"),
              b[13] == UInt8(ascii: ":"), b[16] == UInt8(ascii: ":") else { return nil }

        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for i in range {
                let digit = Int(b[i]) - 48
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }

        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19)
        else { return nil }

        var fraction = 0.0
        if b.count > 20 {
            guard b[19] == UInt8(ascii: ".") else { return nil }
            var scale = 0.1
            for i in 20..<(b.count - 1) {
                let digit = Int(b[i]) - 48
                guard (0...9).contains(digit) else { return nil }
                fraction += Double(digit) * scale
                scale /= 10
            }
        } else if b.count != 20 {
            return nil
        }

        let epochDay = daysFromCivil(year: year, month: month, day: day)
        let seconds = Double(epochDay * 86_400 + hour * 3_600 + minute * 60 + second) + fraction
        return Date(timeIntervalSince1970: seconds)
    }

    /// Howard Hinnant's `days_from_civil`: proleptic Gregorian calendar days since 1970-01-01,
    /// no Calendar/TimeZone lookup involved. The input is always UTC (`Z`), so no zone math
    /// is needed either.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// `nonisolated(unsafe)`: scanning runs on `concurrentPerform`, so several threads share
    /// one formatter. `date(from:)` is documented thread-safe — the compiler just can't prove
    /// it, and building a formatter per call measured an order of magnitude slower.
    private nonisolated(unsafe) static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let iso = ISO8601DateFormatter()
}
