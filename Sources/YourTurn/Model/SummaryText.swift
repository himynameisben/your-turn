import Foundation

/// What to show from a session's summary.
enum NextAction: Sendable, Equatable {
    /// A clear next step was extracted
    case pending(String)
    /// The summary explicitly states there's nothing pending
    case clear
    /// No summary, or no next step could be extracted — falls back to the start of the summary
    case unknown(String?)
}

/// Turns Claude's `away_summary` into "one actionable sentence."
///
/// Why this is the core of the product: measured, 101 of 118 summaries (85%) explicitly
/// state a next step waiting on you. What the user wants is "decide whether to delete
/// upload.py," not "App Store submission tips" — the title describes what's already
/// done, but the next step is the reason they opened this app.
enum SummaryText {
    /// Claude Code appends this hint to the end of the summary; strip it before displaying.
    private static let noise = try! NSRegularExpression(
        pattern: #"\s*\(disable recaps in /config\)\s*$"#
    )

    // NOTE: kept bilingual on purpose — away_summary is free text Claude writes back to
    // you, and its language follows whatever language you were chatting in, not the UI's.
    private static let nextStepMarkers = [
        "下一步", "接下來", "等你", "待你", "需要你", "等待你", "由你決定",
        "next:", "next,", "next step", "awaiting your", "you'll need", "let me know",
    ]

    /// Phrasing that explicitly signals "nothing to do." Must be checked before
    /// nextStepMarkers — "No action pending; awaiting your next request." matches both
    /// marker sets, but the meaning is "nothing pending."
    private static let clearMarkers = [
        "no action pending", "nothing pending", "no further action",
        "沒有待辦", "無待辦", "沒有需要你", "不需要你",
    ]

    static func clean(_ summary: String) -> String {
        let range = NSRange(summary.startIndex..., in: summary)
        return noise.stringByReplacingMatches(in: summary, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func nextAction(from summary: String?) -> NextAction {
        guard let summary else { return .unknown(nil) }
        let text = clean(summary)
        guard !text.isEmpty else { return .unknown(nil) }

        let lowered = text.lowercased()
        if clearMarkers.contains(where: lowered.contains) { return .clear }

        let sentences = split(text)
        // Search from the end: the next step is almost always at the end of the summary.
        if let hit = sentences.last(where: { s in
            let l = s.lowercased()
            return nextStepMarkers.contains { l.contains($0) }
        }) {
            return .pending(stripLeadIn(hit))
        }
        return .unknown(sentences.first ?? text)
    }

    /// Sentence splitting for mixed Chinese/English text.
    ///
    /// CJK terminators (。！？) can be split on unconditionally; the English `.` can't —
    /// measured summaries contain file paths mid-sentence, like `scripts/upload.py` followed
    /// by more clause, or a sentence ending in `apps/web/src/config.ts.`, and splitting on `.`
    /// unconditionally would cut a filename in half. So `.` only ends a sentence when it's
    /// followed by whitespace and an uppercase letter, or when it's at the very end.
    private static func split(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let chars = Array(text)

        for (i, char) in chars.enumerated() {
            current.append(char)
            let isCJKStop = "。！？".contains(char)
            let isLatinStop = ".!?".contains(char) && latinStopEndsSentence(chars, at: i)
            guard isCJKStop || isLatinStop else { continue }

            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { sentences.append(trimmed) }
            current = ""
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    private static func latinStopEndsSentence(_ chars: [Character], at index: Int) -> Bool {
        var next = index + 1
        guard next < chars.count else { return true }          // end of text
        guard chars[next].isWhitespace else { return false }    // "config.ts" doesn't split
        while next < chars.count, chars[next].isWhitespace { next += 1 }
        guard next < chars.count else { return true }
        return chars[next].isUppercase                          // only splits on ". Next:"
    }

    /// Strips lead-ins like "Next step:" — the whole UI's context is already the next
    /// step, so repeating it is redundant.
    private static func stripLeadIn(_ sentence: String) -> String {
        var s = sentence
        for marker in ["下一步是", "下一步：", "下一步:", "下一步", "接下來：", "接下來:", "接下來",
                       "Next:", "Next,", "next:", "next,"] {
            guard s.hasPrefix(marker) else { continue }
            s = String(s.dropFirst(marker.count))
            break
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " 　:：,，、"))
    }
}
