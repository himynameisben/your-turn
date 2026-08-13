import Foundation

/// Number formatting shared by the stats window and `--cost`.
///
/// Deliberately not localized. These are magnitudes, not sentences — `$6,180`, `7.4G`,
/// `331h` read the same in both languages, and keeping one implementation means the window
/// and the CLI can never disagree about what a number is.
enum StatsFormat {
    /// Cents matter below $100 and stop mattering above it: at $6,180 the last two digits are
    /// noise from a 0.06%-accurate estimate, and printing them implies precision that isn't there.
    static func usd(_ value: Double) -> String {
        if value >= 100 { return "$" + grouped(Int(value.rounded())) }
        if value >= 1 { return String(format: "$%.2f", value) }
        return value > 0 ? String(format: "$%.3f", value) : "$0"
    }

    static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000_000...: String(format: "%.1fG", Double(count) / 1e9)
        case 1_000_000...: String(format: "%.1fM", Double(count) / 1e6)
        case 1_000...: String(format: "%.1fK", Double(count) / 1e3)
        default: "\(count)"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: String(format: "%.0fs", seconds)
        case ..<3600: String(format: "%.0fm", seconds / 60)
        case ..<(100 * 3600): String(format: "%.1fh", seconds / 3600)
        default: String(format: "%.0fh", seconds / 3600)
        }
    }

    static func percent(_ part: Int, of whole: Int) -> String {
        whole > 0 ? String(format: "%.0f%%", Double(part) * 100 / Double(whole)) : "—"
    }

    static func bytes(_ count: Int) -> String {
        count >= 1 << 30
            ? String(format: "%.1fGB", Double(count) / Double(1 << 30))
            : String(format: "%.0fMB", Double(count) / Double(1 << 20))
    }

    static func milliseconds(_ seconds: TimeInterval) -> String {
        seconds < 1 ? String(format: "%.0fms", seconds * 1000) : String(format: "%.2fs", seconds)
    }

    private static func grouped(_ value: Int) -> String {
        let digits = String(value)
        guard digits.count > 3 else { return digits }
        var result = ""
        for (offset, character) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return result
    }
}
