import Foundation

/// Implementation of `YourTurn --dump`: no UI, just prints the scan results to stdout.
///
/// This is the verification entry point for the data layer — you can cross-check it
/// directly against `pgrep -x claude` and `ls -lt ~/.claude/projects/*/` to confirm the
/// state detection is correct.
enum DumpCommand {
    static func run() {
        let started = Date()
        let sessions = SessionScanner.scan()
        let scanTime = Date().timeIntervalSince(started)

        let probeStarted = Date()
        let processes = ProcessProbe.liveProcesses()
        let probeTime = Date().timeIntervalSince(probeStarted)

        let registry = SessionRegistry.read(livePIDs: Set(processes.map(\.pid)))
        let now = Date()
        let groups = SessionResolver.resolve(
            sessions, processes: processes, registry: registry, now: now
        )

        for group in groups {
            let open = group.sessions.count(where: \.isLive)
            print("\n\(group.name)\(open > 0 ? "  [\(open) terminal(s) open]" : "")")
            print("  \(group.path)")
            for item in group.sessions {
                let session = item.session
                let branch = session.gitBranch.map { " (\($0))" } ?? ""
                // "registry" means the state came straight from Claude's own report, not a guess.
                let source = item.live == nil ? "" : "  ·  registry"
                let waiting = item.waitingFor.map { "  ·  waiting for you: \($0)" } ?? ""
                print("    [\(item.state.label)] \(session.displayTitle)\(branch)")
                print("        \(relative(session.lastActivity, from: now))  ·  \(session.id.prefix(8))\(source)\(waiting)")
                print("        → \(jumpTarget(item))")
                if let you = session.youSaid {
                    print("        You  \(truncate(you, 120))")
                }
                if let ai = item.actionLine {
                    print("        AI   \(truncate(ai, 150))")
                }
            }
        }

        let all = groups.flatMap(\.sessions)
        let states = all.reduce(into: [SessionState: Int]()) { $0[$1.state, default: 0] += 1 }
        let hosts = processes.reduce(into: [String: Int]()) { $0[$1.host.displayName, default: 0] += 1 }
        print("""

        ── Stats ──────────────────────────────
        sessions        \(all.count) across \(groups.count) project(s)
        live processes  \(processes.count) — \(hosts.map { "\($0.key) \($0.value)" }.sorted().joined(separator: " · "))
        registry        \(registry.count)/\(processes.count) processes registered (rest fall back to guessing)
        states          running \(states[.running] ?? 0) · waiting for you \(states[.awaiting] ?? 0) · \
        done \(states[.finished] ?? 0)
        with title      \(all.count { $0.session.title != nil })/\(all.count)
        with summary    \(all.count { $0.session.summary != nil })/\(all.count)
        time            scan \(ms(scanTime)) + process probe \(ms(probeTime))
        """)
    }

    /// Verifies the quality of "next action" extraction. This is exactly the line shown for
    /// every row in the list — get it wrong and the product fails.
    static func verifyNextActions() {
        let sessions = SessionScanner.scan()
        var pending = 0, clear = 0, unknown = 0, noSummary = 0
        var lengths: [Int] = []

        for session in sessions {
            switch session.nextAction {
            case .pending(let text):
                pending += 1
                lengths.append(text.count)
                guard let summary = session.summary else { continue }
                let original = SummaryText.clean(summary)
                // If extraction barely shortens the text, sentence splitting likely failed
                // and treated the whole block as a single sentence.
                if text.count > original.count * 4 / 5 && original.count > 120 {
                    print("⚠️ Sentence split may have failed (\(original.count)→\(text.count)) \(session.projectName)")
                    print("   \(truncate(text, 110))")
                }
            case .clear: clear += 1
            case .unknown: session.summary == nil ? (noSummary += 1) : (unknown += 1)
            }
        }

        let withSummary = pending + clear + unknown
        print("\n── Extraction results for \(sessions.count) session(s) ──────────")
        print("with summary        \(withSummary) (\(noSummary) with no summary, need fallback)")
        print("  ├ has next action \(pending)  (\(pending * 100 / max(withSummary, 1))% of with-summary)")
        print("  ├ clearly done    \(clear)")
        print("  └ couldn't tell   \(unknown)")
        if !lengths.isEmpty {
            let sorted = lengths.sorted()
            print("length              median \(sorted[sorted.count / 2]) chars · max \(sorted.last!) chars")
        }

        print("\n── Sample (most recent 8) ──────────")
        for session in sessions.prefix(8) {
            print("\n[\(session.projectName)]")
            switch session.nextAction {
            case .pending(let text): print("  ▸ \(truncate(text, 100))")
            case .clear: print("  ✓ nothing pending")
            case .unknown(let fallback): print("  ? \(fallback.map { truncate($0, 100) } ?? "no summary")")
            }
        }
    }

    /// Cross-analysis: "is the terminal open" and "is there an unfinished next action" are
    /// two independent axes — the inbox currently filters only on the former. This command
    /// checks how badly the two diverge.
    static func triage() {
        let sessions = SessionScanner.scan()
        let processes = ProcessProbe.liveProcesses()
        let registry = SessionRegistry.read(livePIDs: Set(processes.map(\.pid)))
        let now = Date()
        let items = SessionResolver
            .resolve(sessions, processes: processes, registry: registry, now: now)
            .flatMap(\.sessions)

        func bucket(_ item: ResolvedSession) -> String {
            switch item.session.nextAction {
            case .pending: "pending"
            case .clear: "clear"
            case .unknown: "unknown"
            }
        }

        // Keyed by the enum, not by `state.label`: a row list of hand-written label strings
        // silently zeroes out the whole table the moment the labels are reworded.
        var table: [SessionState: [String: Int]] = [:]
        for item in items {
            table[item.state, default: [:]][bucket(item), default: 0] += 1
        }

        // Padded in Swift, not with `%-16@`: String(format:) silently drops the field width
        // on `%@`, which left every label butted against its first column.
        print("\n                  pending  clear  unknown")
        for state in [SessionState.running, .awaiting, .finished] {
            let row = table[state] ?? [:]
            print(String(format: "%@  %7d  %5d  %7d", pad(state.label, 16),
                         row["pending"] ?? 0, row["clear"] ?? 0, row["unknown"] ?? 0))
        }

        let orphaned = items.filter {
            $0.state == .finished && $0.session.isRecent(now: now)
                && { if case .pending = $0.session.nextAction { true } else { false } }($0)
        }
        print("\n── Missed (within 3 days, has a pending action, but terminal is closed): \(orphaned.count) ──")
        for item in orphaned.prefix(6) {
            print("\n[\(item.session.projectName)] \(relative(item.session.lastActivity, from: now))")
            if case .pending(let text) = item.session.nextAction {
                print("  ▸ \(truncate(text, 100))")
            }
        }

        let noisy = items.filter { $0.state == .awaiting }
            .filter { if case .clear = $0.session.nextAction { true } else { false } }
        print("\n── Misplaced in the inbox (terminal open but clearly nothing pending): \(noisy.count) ──")
        for item in noisy.prefix(4) { print("  · \(item.session.projectName) — \(item.session.displayTitle)") }

        // Age distribution of pending items, used to decide how wide the inbox's time window should be.
        let todos = items.filter { if case .pending = $0.session.nextAction { true } else { false } }
        print("\n── Age distribution of \(todos.count) pending item(s) ──")
        let buckets: [(String, TimeInterval, TimeInterval)] = [
            ("today", 0, 86_400), ("1-3 days", 86_400, 259_200),
            ("3-7 days", 259_200, 604_800), ("7+ days", 604_800, .greatestFiniteMagnitude),
        ]
        for (label, lo, hi) in buckets {
            let n = todos.count { item -> Bool in
                let age = now.timeIntervalSince(item.session.lastActivity)
                return age >= lo && age < hi
            }
            print("  \(label.padding(toLength: 10, withPad: " ", startingAt: 0)) \(n)")
        }

        // Project-level rollup — what each card in the grid would show.
        print("\n── Project rollup (pending count · running/open · last activity) ──")
        let byProject = Dictionary(grouping: items, by: \.session.projectName)
            .map { name, list -> (String, Int, Int, Date) in
                let todo = list.count { if case .pending = $0.session.nextAction { true } else { false } }
                let live = list.count { $0.state == .running || $0.state == .awaiting }
                return (name, todo, live, list.map(\.session.lastActivity).max() ?? .distantPast)
            }
            .sorted { $0.3 > $1.3 }
        for (name, todo, live, last) in byProject.prefix(12) {
            print("  \(pad(name, 24)) pending \(pad(String(todo), 2, left: false)) · open \(live) · \(relative(last, from: now))")
        }
        print("  … \(byProject.count) project(s) total, \(byProject.count { $0.1 > 0 }) with pending items")
    }

    /// Prints what would happen if you clicked "jump" — lets you check the jump target directly.
    private static func jumpTarget(_ item: ResolvedSession) -> String {
        guard let process = item.process else {
            return "open new window · claude --resume \(item.session.id.prefix(8))"
        }
        switch process.host {
        case .iterm:
            return "focus iTerm2 tab · \(process.tty ?? "?")"
        case .appleTerminal:
            return "focus Terminal tab · \(process.tty ?? "?")"
        case .app(let bundleID, let name, let port):
            let workspace = port.flatMap(IDELockReader.workspace)
            return "focus \(name) window · \(workspace ?? item.session.projectPath)"
                + (port.map { "  (ide port \($0))" } ?? "")
                + (process.tty == nil ? "  (no tty — ACP?)" : "")
                + "  [\(bundleID)]"
        case .other(let name):
            return "open project folder (no bundle id, host \(name ?? "?"))"
        }
    }

    private static func ms(_ t: TimeInterval) -> String { String(format: "%.0fms", t * 1000) }

    /// Column padding, since `String(format:)` drops the field width on `%@` and the
    /// stdlib's `padding(toLength:)` only ever pads on the right.
    private static func pad(_ s: String, _ width: Int, left: Bool = true) -> String {
        guard s.count < width else { return String(s.prefix(width)) }
        let spaces = String(repeating: " ", count: width - s.count)
        return left ? s + spaces : spaces + s
    }

    private static func relative(_ date: Date, from now: Date) -> String {
        let s = Int(now.timeIntervalSince(date))
        switch s {
        case ..<60: return "\(s)s ago"
        case ..<3600: return "\(s / 60)m ago"
        case ..<86400: return "\(s / 3600)h ago"
        default: return "\(s / 86400)d ago"
        }
    }

    private static func truncate(_ s: String, _ limit: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : flat.prefix(limit) + "…"
    }
}
